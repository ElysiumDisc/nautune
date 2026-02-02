import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' show Random, max, pi, cos, sin;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/chart_data.dart';
import '../models/download_item.dart';
import '../providers/demo_mode_provider.dart';
import '../services/chart_cache_service.dart';
import '../services/chart_generator_service.dart';
import '../services/listening_analytics_service.dart';
import '../widgets/jellyfin_image.dart';

/// Frets on Fire - Guitar Hero style rhythm game easter egg.
/// Search "fire" in Library to discover this screen.
class FretsOnFireScreen extends StatefulWidget {
  const FretsOnFireScreen({super.key});

  @override
  State<FretsOnFireScreen> createState() => _FretsOnFireScreenState();
}

class _FretsOnFireScreenState extends State<FretsOnFireScreen>
    with TickerProviderStateMixin {
  // Services
  final _chartGenerator = ChartGeneratorService.instance;
  final _chartCache = ChartCacheService.instance;
  NautuneAppState? _appState;

  // Game state
  GameState _gameState = GameState.selectTrack;
  ChartData? _chart;
  String? _selectedTrackPath;

  // Audio player for game (separate from main player)
  final AudioPlayer _gamePlayer = AudioPlayer();
  Duration _position = Duration.zero;

  // Gameplay
  int _score = 0;
  int _combo = 0;
  int _maxCombo = 0;
  int _multiplier = 1;
  int _perfectHits = 0;
  int _goodHits = 0;
  int _missedNotes = 0;
  int _nextNoteIndex = 0;

  // Active bonuses
  BonusType? _activeBonus;
  DateTime? _bonusExpiry;
  int _shieldCharges = 0;
  int? _lightningLane; // Which lane is being auto-hit
  bool _doublePointsActive = false;
  bool _noteMagnetActive = false;
  int _bonusesCollected = 0;

  // Hit feedback
  String? _hitFeedbackText;
  Color? _hitFeedbackColor;
  DateTime? _hitFeedbackTime;
  int? _hitFeedbackLane;

  // Particle effects
  final List<_Particle> _particles = [];
  final Random _random = Random();

  // Animation
  late AnimationController _noteController;

  // Streak feedback animations
  late AnimationController _multiplierPulseController;
  late AnimationController _milestoneFlashController;
  late Animation<double> _multiplierPulse;
  late Animation<double> _milestoneFlash;
  String? _milestoneText; // "ON FIRE!", "BLAZING!", "INFERNO!"
  bool _showStreakFire = false; // Show fire effect when on a streak

  // Keyboard focus
  final FocusNode _focusNode = FocusNode();

  // Timing windows - calculated from BPM like original Frets on Fire
  // Original formula: 60000 / BPM / 3.5 for hit window
  int get _hitWindow => _chart != null ? (60000 / _chart!.bpm / 3.5).round() : 143;
  int get _perfectWindow => (_hitWindow * 0.4).round(); // Tighter window for perfect
  static const int _noteLeadTime = 2000; // Notes visible 2 seconds before hit

  // Lane states for visual feedback (5 frets like original)
  final List<bool> _lanePressed = [false, false, false, false, false];
  final List<DateTime?> _laneHitTime = [null, null, null, null, null];

  // Legendary track unlock state
  bool _showLegendaryUnlock = false;
  bool _showLegendaryDownloadPrompt = false;

  @override
  void initState() {
    super.initState();
    _chartCache.initialize().then((_) {
      // Check if legendary track is unlocked but not downloaded
      _checkLegendaryDownloadPrompt();
    });

    // Mark easter egg as discovered for milestone badge
    ListeningAnalyticsService().markFretsOnFireDiscovered();

    _noteController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 16), // ~60fps
    )..addListener(_onFrame);

    // Multiplier pulse animation (continuous when on streak)
    _multiplierPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _multiplierPulse = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _multiplierPulseController, curve: Curves.easeInOut),
    );

    // Milestone flash animation (one-shot when hitting 10/20/30 combo)
    // Long duration (2.5 seconds) - stays visible for 70%, fades for 30%
    _milestoneFlashController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );
    _milestoneFlash = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _milestoneFlashController, curve: Curves.easeOut),
    );
    _milestoneFlashController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _milestoneText = null);
      }
    });

    _gamePlayer.onPositionChanged.listen((pos) {
      if (mounted) {
        setState(() => _position = pos);
      }
    });

    _gamePlayer.onDurationChanged.listen((dur) {
      // Duration tracked for reference, not used in UI currently
    });

    _gamePlayer.onPlayerComplete.listen((_) {
      if (mounted && _gameState == GameState.playing) {
        _endGame();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _appState ??= context.read<NautuneAppState>();
  }

  @override
  void dispose() {
    _noteController.dispose();
    _multiplierPulseController.dispose();
    _milestoneFlashController.dispose();
    _gamePlayer.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onFrame() {
    if (_gameState != GameState.playing || _chart == null) return;

    final currentMs = _position.inMilliseconds;

    // Update particle effects
    _updateParticles();

    // Check bonus expiry
    _checkBonusExpiry();

    // Handle lightning lane auto-hits
    if (_lightningLane != null) {
      _handleLightningLaneAutoHits(currentMs);
    }

    // Check for missed notes (past the hit window)
    while (_nextNoteIndex < _chart!.notes.length) {
      final note = _chart!.notes[_nextNoteIndex];
      // Skip bonus notes for miss detection (they just disappear if not hit)
      if (note.isBonus) {
        if (note.timestampMs < currentMs - _hitWindow) {
          _nextNoteIndex++;
        } else {
          break;
        }
        continue;
      }
      if (note.timestampMs < currentMs - _hitWindow) {
        // Missed this note - check shield
        _missNote();
        _nextNoteIndex++;
      } else {
        break;
      }
    }

    if (mounted) setState(() {});
  }

  void _updateParticles() {
    final now = DateTime.now();
    _particles.removeWhere((p) => now.difference(p.createdAt).inMilliseconds > p.lifetimeMs);
    for (final p in _particles) {
      final age = now.difference(p.createdAt).inMilliseconds;
      p.x += p.vx;
      p.y += p.vy;
      p.vy += 0.2; // gravity
      p.opacity = 1.0 - (age / p.lifetimeMs);
    }
  }

  void _checkBonusExpiry() {
    if (_bonusExpiry != null && DateTime.now().isAfter(_bonusExpiry!)) {
      _activeBonus = null;
      _bonusExpiry = null;
      _lightningLane = null;
      _doublePointsActive = false;
      _noteMagnetActive = false;
    }
  }

  void _handleLightningLaneAutoHits(int currentMs) {
    // Auto-hit any notes in the lightning lane that are within the hit window
    for (int i = _nextNoteIndex; i < _chart!.notes.length; i++) {
      final note = _chart!.notes[i];
      if (note.lane != _lightningLane) continue;
      if (note.isBonus) continue;

      final diff = note.timestampMs - currentMs;
      if (diff <= 50 && diff >= -50) {
        // Auto-hit with perfect timing
        _hitNote(_lightningLane!, true);
        _spawnParticles(_lightningLane!, isLightning: true);
        if (i == _nextNoteIndex) _nextNoteIndex++;
      } else if (diff > 50) {
        break;
      }
    }
  }

  void _missNote() {
    // Shield protects combo from misses
    if (_shieldCharges > 0) {
      _shieldCharges--;
      // Show shield absorbed feedback
      _triggerMilestone('SHIELDED!');
      return;
    }

    _missedNotes++;
    _combo = 0;
    _multiplier = 1;
    _showStreakFire = false;
    _multiplierPulseController.stop();
    _multiplierPulseController.reset();
  }

  void _hitNote(int lane, bool isPerfect) {
    // Calculate effective multiplier (with double points bonus)
    final effectiveMultiplier = _doublePointsActive ? _multiplier * 2 : _multiplier;

    // Scoring like original Frets on Fire: 50 points per note * multiplier
    if (isPerfect) {
      _perfectHits++;
      _score += 50 * effectiveMultiplier;
      _showHitFeedback(lane, 'PERFECT', const Color(0xFFFFD700));
    } else {
      _goodHits++;
      _score += 50 * effectiveMultiplier;
      _showHitFeedback(lane, 'GOOD', Colors.white);
    }

    _combo++;
    _maxCombo = max(_maxCombo, _combo);

    // Spawn hit particles
    _spawnParticles(lane);

    // Multiplier milestones like original: 10→2x, 20→3x, 30→4x (max 4x)
    if (_combo == 10) {
      _multiplier = 2;
      _triggerMilestone('ON FIRE!');
      _spawnMilestoneParticles();
    } else if (_combo == 20) {
      _multiplier = 3;
      _triggerMilestone('BLAZING!');
      _spawnMilestoneParticles();
    } else if (_combo == 30) {
      _multiplier = 4;
      _triggerMilestone('INFERNO!');
      _spawnMilestoneParticles();
    } else if (_combo == 50) {
      _triggerMilestone('LEGENDARY!');
      _spawnMilestoneParticles();
    } else if (_combo == 100) {
      _triggerMilestone('GODLIKE!');
      _spawnMilestoneParticles();
    }

    // Start/maintain streak fire effect and multiplier pulse
    if (_combo >= 10) {
      _showStreakFire = true;
      if (!_multiplierPulseController.isAnimating) {
        _multiplierPulseController.repeat(reverse: true);
      }
    }

    _laneHitTime[lane] = DateTime.now();
  }

  void _showHitFeedback(int lane, String text, Color color) {
    _hitFeedbackText = text;
    _hitFeedbackColor = color;
    _hitFeedbackTime = DateTime.now();
    _hitFeedbackLane = lane;
  }

  void _spawnParticles(int lane, {bool isLightning = false}) {
    final laneX = (lane + 0.5) / 5.0; // Normalized X position
    final particleCount = isLightning ? 12 : 6;
    final color = isLightning ? const Color(0xFF00BFFF) : const Color(0xFFFF6B35);

    for (int i = 0; i < particleCount; i++) {
      final angle = _random.nextDouble() * 2 * pi;
      final speed = 2.0 + _random.nextDouble() * 4.0;
      _particles.add(_Particle(
        x: laneX,
        y: 0.85, // Hit line position
        vx: cos(angle) * speed * 0.01,
        vy: -sin(angle).abs() * speed * 0.015, // Always go up initially
        color: color,
        size: isLightning ? 4.0 + _random.nextDouble() * 3.0 : 2.0 + _random.nextDouble() * 2.0,
        lifetimeMs: 400 + _random.nextInt(200),
        createdAt: DateTime.now(),
      ));
    }
  }

  void _spawnMilestoneParticles() {
    // Spawn a burst of particles across the screen
    for (int i = 0; i < 30; i++) {
      final x = _random.nextDouble();
      final angle = _random.nextDouble() * 2 * pi;
      final speed = 3.0 + _random.nextDouble() * 5.0;
      _particles.add(_Particle(
        x: x,
        y: 0.5,
        vx: cos(angle) * speed * 0.015,
        vy: sin(angle) * speed * 0.015,
        color: Color.lerp(const Color(0xFFFF6B35), const Color(0xFFFFD700), _random.nextDouble())!,
        size: 3.0 + _random.nextDouble() * 4.0,
        lifetimeMs: 600 + _random.nextInt(400),
        createdAt: DateTime.now(),
      ));
    }
  }

  void _collectBonus(BonusType bonusType) {
    _bonusesCollected++;

    switch (bonusType) {
      case BonusType.lightningLane:
        // Pick a random lane to auto-hit
        _lightningLane = _random.nextInt(5);
        _activeBonus = bonusType;
        _bonusExpiry = DateTime.now().add(const Duration(seconds: 5));
        _triggerMilestone('LIGHTNING!');
        break;

      case BonusType.shield:
        _shieldCharges = 2; // Protects 2 misses
        _triggerMilestone('SHIELD!');
        break;

      case BonusType.doublePoints:
        _doublePointsActive = true;
        _activeBonus = bonusType;
        _bonusExpiry = DateTime.now().add(const Duration(seconds: 5));
        _triggerMilestone('2X POINTS!');
        break;

      case BonusType.multiplierBoost:
        _multiplier = 4;
        _combo = max(_combo, 30); // Ensure combo supports 4x
        _showStreakFire = true;
        if (!_multiplierPulseController.isAnimating) {
          _multiplierPulseController.repeat(reverse: true);
        }
        _triggerMilestone('MAX POWER!');
        break;

      case BonusType.noteMagnet:
        _noteMagnetActive = true;
        _activeBonus = bonusType;
        _bonusExpiry = DateTime.now().add(const Duration(seconds: 3));
        _triggerMilestone('MAGNET!');
        break;
    }

    // Spawn golden particles for bonus
    for (int i = 0; i < 20; i++) {
      final angle = _random.nextDouble() * 2 * pi;
      final speed = 2.0 + _random.nextDouble() * 6.0;
      _particles.add(_Particle(
        x: 0.5,
        y: 0.5,
        vx: cos(angle) * speed * 0.02,
        vy: sin(angle) * speed * 0.02,
        color: const Color(0xFFFFD700),
        size: 4.0 + _random.nextDouble() * 4.0,
        lifetimeMs: 800 + _random.nextInt(400),
        createdAt: DateTime.now(),
      ));
    }
  }

  void _triggerMilestone(String text) {
    _milestoneText = text;
    _milestoneFlashController.forward(from: 0);
  }

  void _onLaneTap(int lane) {
    if (_gameState != GameState.playing || _chart == null) return;
    if (lane < 0 || lane >= 5) return; // Validate lane index

    _lanePressed[lane] = true;
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _lanePressed[lane] = false);
    });

    final currentMs = _position.inMilliseconds;

    // Effective hit window (Note Magnet makes it more forgiving)
    final effectiveHitWindow = _noteMagnetActive ? (_hitWindow * 1.5).round() : _hitWindow;
    final effectivePerfectWindow = _noteMagnetActive ? (_hitWindow * 0.8).round() : _perfectWindow;

    // Find a note in this lane that's within the hit window
    for (int i = _nextNoteIndex; i < _chart!.notes.length; i++) {
      final note = _chart!.notes[i];
      if (note.lane != lane) continue;

      final diff = (note.timestampMs - currentMs).abs();

      // Handle bonus notes
      if (note.isBonus && diff <= effectiveHitWindow) {
        if (note.bonusType != null) {
          _collectBonus(note.bonusType!);
        }
        _nextNoteIndex = i + 1;
        setState(() {});
        return;
      }

      // Regular notes
      if (diff <= effectivePerfectWindow) {
        _hitNote(lane, true);
        _nextNoteIndex = i + 1;
        setState(() {});
        return;
      } else if (diff <= effectiveHitWindow) {
        _hitNote(lane, false);
        _nextNoteIndex = i + 1;
        setState(() {});
        return;
      }

      // Notes are sorted, so if this note is too far in the future, stop looking
      if (note.timestampMs > currentMs + effectiveHitWindow) break;
    }
  }

  Future<void> _selectTrack() async {
    // Get downloaded tracks from download service
    final downloads = _appState?.downloadService.completedDownloads ?? [];
    final isDemoMode = context.read<DemoModeProvider>().isDemoMode;
    final isOfflineMode = _appState?.isOfflineMode ?? false;

    // Legendary track is ALWAYS available in demo mode or offline mode (bundled in app)
    // In normal online mode, it requires unlocking via perfect score
    final legendaryAvailable = isDemoMode || isOfflineMode || _chartCache.isLegendaryUnlocked;

    // Make sure the legendary track file is ready (copy from assets if needed)
    String? legendaryPath = _chartCache.legendaryTrackPath;
    if (legendaryAvailable && !_chartCache.isLegendaryReady) {
      // Auto-prepare the legendary track from bundled assets
      await _chartCache.prepareLegendaryTrack();
      if (!mounted) return;
      legendaryPath = _chartCache.legendaryTrackPath;
    }
    final legendaryReady = legendaryAvailable && _chartCache.isLegendaryReady;

    if (downloads.isEmpty && !legendaryReady) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No downloaded tracks available')),
        );
      }
      return;
    }

    if (!mounted) return;

    // Show track selection dialog
    final selected = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _TrackSelectionDialog(
        downloads: downloads,
        legendaryReady: legendaryReady,
        legendaryPath: legendaryPath,
        legendaryTrackName: _chartCache.legendaryTrackName,
        legendaryArtistName: _chartCache.legendaryArtistName,
        legendaryTrackId: _chartCache.legendaryTrackId,
        isDemoMode: isDemoMode,
      ),
    );

    if (selected != null && mounted) {
      setState(() {
        _selectedTrackPath = selected['path'];
        _gameState = GameState.analyzing;
      });
      _analyzeTrack(
        selected['path']!,
        selected['id']!,
        selected['name']!,
        selected['artist']!,
        int.parse(selected['duration']!),
      );
    }
  }

  Future<void> _analyzeTrack(
    String path,
    String trackId,
    String trackName,
    String artistName,
    int durationMs,
  ) async {
    // Check cache first
    final cached = _chartCache.getChart(trackId);
    if (cached != null) {
      setState(() {
        _chart = cached;
        _gameState = GameState.ready;
      });
      return;
    }

    // Check duration limit before analyzing
    final durationError = _chartGenerator.checkDurationLimit(durationMs);
    if (durationError != null && mounted) {
      setState(() => _gameState = GameState.selectTrack);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Track too long: ${(durationMs / 60000).toStringAsFixed(0)} min. '
              'Max ${_chartGenerator.maxDurationMinutes} min for stability.'),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }

    // Generate new chart
    final chart = await _chartGenerator.generateChart(
      audioPath: path,
      trackId: trackId,
      trackName: trackName,
      artistName: artistName,
      durationMs: durationMs,
    );

    if (chart != null && mounted) {
      await _chartCache.saveChart(chart);
      setState(() {
        _chart = chart;
        _gameState = GameState.ready;
      });
    } else if (mounted) {
      setState(() => _gameState = GameState.selectTrack);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to analyze track')),
      );
    }
  }

  Future<void> _startGame() async {
    if (_chart == null || _selectedTrackPath == null) return;

    // Reset game state
    _score = 0;
    _combo = 0;
    _maxCombo = 0;
    _multiplier = 1;
    _perfectHits = 0;
    _goodHits = 0;
    _missedNotes = 0;
    _nextNoteIndex = 0;

    // Reset bonus state
    _activeBonus = null;
    _bonusExpiry = null;
    _shieldCharges = 0;
    _lightningLane = null;
    _doublePointsActive = false;
    _noteMagnetActive = false;
    _bonusesCollected = 0;
    _particles.clear();
    _hitFeedbackText = null;

    // Start audio
    await _gamePlayer.play(DeviceFileSource(_selectedTrackPath!));

    setState(() => _gameState = GameState.playing);
    _noteController.repeat();
    _focusNode.requestFocus();
  }

  void _pauseGame() {
    _gamePlayer.pause();
    _noteController.stop();
    setState(() => _gameState = GameState.paused);
  }

  void _resumeGame() {
    _gamePlayer.resume();
    _noteController.repeat();
    setState(() => _gameState = GameState.playing);
    _focusNode.requestFocus();
  }

  void _endGame() {
    _noteController.stop();
    _gamePlayer.stop();

    // Check for remaining notes as missed
    while (_nextNoteIndex < (_chart?.notes.length ?? 0)) {
      _missedNotes++;
      _nextNoteIndex++;
    }

    // Update high score
    if (_chart != null && _score > _chart!.highScore) {
      _chartCache.updateScore(_chart!.trackId, _score, _multiplier);
    }

    // Check for PERFECT score - unlock legendary track!
    final totalNotes = _chart?.notes.length ?? 0;
    if (_chartCache.isPerfectScore(_perfectHits, _goodHits, _missedNotes, totalNotes)) {
      if (!_chartCache.isLegendaryUnlocked) {
        _chartCache.unlockLegendaryTrack();
        _showLegendaryUnlock = true;
      }
    }

    setState(() => _gameState = GameState.ended);
  }

  void _checkLegendaryDownloadPrompt() {
    if (_chartCache.isLegendaryUnlocked && !_chartCache.isLegendaryReady) {
      // Auto-prepare the legendary track from bundled assets
      _prepareLegendaryTrack();
    }
  }

  Future<void> _prepareLegendaryTrack() async {
    setState(() => _showLegendaryDownloadPrompt = false);
    final success = await _chartCache.prepareLegendaryTrack();
    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔥 Through the Fire and Flames ready to play!'),
          backgroundColor: Color(0xFFFF6B35),
        ),
      );
      setState(() {}); // Refresh to show in track list
    }
  }

  void _restartGame() {
    setState(() => _gameState = GameState.ready);
  }

  void _backToSelect() {
    _gamePlayer.stop();
    setState(() {
      _gameState = GameState.selectTrack;
      _chart = null;
      _selectedTrackPath = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _gameState == GameState.playing
          ? null
          : AppBar(
              backgroundColor: Colors.transparent,
              title: Text(
                'FRETS ON FIRE',
                style: GoogleFonts.raleway(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 3,
                  fontSize: 20,
                ),
              ),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.pop(context),
              ),
            ),
      body: Stack(
        children: [
          KeyboardListener(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _handleKeyEvent,
            child: _buildBody(theme),
          ),
          // Legendary track download prompt overlay
          if (_showLegendaryDownloadPrompt)
            _buildLegendaryDownloadPrompt(theme),
        ],
      ),
    );
  }

  Widget _buildLegendaryDownloadPrompt(ThemeData theme) {
    const fireOrange = Color(0xFFFF6B35);
    const fireRed = Color(0xFFFF4D6D);
    const fireYellow = Color(0xFFFFD700);

    return Container(
      color: Colors.black87,
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(32),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                const Color(0xFF1A0A0A),
                fireRed.withValues(alpha: 0.2),
              ],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: fireOrange.withValues(alpha: 0.5), width: 2),
            boxShadow: [
              BoxShadow(
                color: fireOrange.withValues(alpha: 0.3),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.local_fire_department, color: fireYellow, size: 56),
              const SizedBox(height: 16),
              Text(
                'LEGENDARY UNLOCKED!',
                style: GoogleFonts.pacifico(
                  color: fireYellow,
                  fontSize: 24,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Through the Fire and Flames',
                style: GoogleFonts.raleway(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              Text(
                'by DragonForce',
                style: GoogleFonts.raleway(
                  color: Colors.white70,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'The ultimate Guitar Hero track awaits!',
                style: GoogleFonts.raleway(
                  color: fireOrange,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (_chartCache.isLegendaryCopying) ...[
                const CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation(fireOrange),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Preparing...',
                  style: TextStyle(color: Colors.white54),
                ),
              ] else ...[
                ElevatedButton.icon(
                  onPressed: _prepareLegendaryTrack,
                  icon: const Icon(Icons.local_fire_department),
                  label: const Text('UNLOCK'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: fireOrange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => setState(() => _showLegendaryDownloadPrompt = false),
                  child: const Text('Later', style: TextStyle(color: Colors.white54)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (_gameState != GameState.playing) return;

    // Map keys to 5 lanes: 1-5 or F1-F5
    int? lane;
    if (event.logicalKey == LogicalKeyboardKey.digit1 ||
        event.logicalKey == LogicalKeyboardKey.f1) {
      lane = 0;
    } else if (event.logicalKey == LogicalKeyboardKey.digit2 ||
        event.logicalKey == LogicalKeyboardKey.f2) {
      lane = 1;
    } else if (event.logicalKey == LogicalKeyboardKey.digit3 ||
        event.logicalKey == LogicalKeyboardKey.f3) {
      lane = 2;
    } else if (event.logicalKey == LogicalKeyboardKey.digit4 ||
        event.logicalKey == LogicalKeyboardKey.f4) {
      lane = 3;
    } else if (event.logicalKey == LogicalKeyboardKey.digit5 ||
        event.logicalKey == LogicalKeyboardKey.f5) {
      lane = 4;
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      _pauseGame();
      return;
    } else if (event.logicalKey == LogicalKeyboardKey.keyF) {
      // Cheat key: Press F to ignite! Instant fire mode
      _activateFireMode();
      return;
    }

    if (lane != null) {
      _onLaneTap(lane);
    }
  }

  /// Cheat: Press F to activate fire mode instantly
  void _activateFireMode() {
    if (_gameState != GameState.playing) return;

    // Boost combo to trigger max multiplier
    _combo = 30;
    _multiplier = 4;
    _showStreakFire = true;

    // Start the pulse animation
    if (!_multiplierPulseController.isAnimating) {
      _multiplierPulseController.repeat(reverse: true);
    }

    // Show the message
    _triggerMilestone('IGNITED!');

    setState(() {});
  }

  Widget _buildBody(ThemeData theme) {
    switch (_gameState) {
      case GameState.selectTrack:
        return _buildTrackSelect(theme);
      case GameState.analyzing:
        return _buildAnalyzing(theme);
      case GameState.ready:
        return _buildReady(theme);
      case GameState.playing:
        return _buildPlaying(theme);
      case GameState.paused:
        return _buildPaused(theme);
      case GameState.ended:
        return _buildEnded(theme);
    }
  }

  Widget _buildTrackSelect(ThemeData theme) {
    final isDemoMode = context.watch<DemoModeProvider>().isDemoMode;
    final isOfflineMode = _appState?.isOfflineMode ?? false;
    // Legendary is always available in demo/offline mode
    final legendaryAvailable = isDemoMode || isOfflineMode || _chartCache.isLegendaryUnlocked;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.local_fire_department,
              size: 80,
              color: legendaryAvailable ? const Color(0xFFFF6B35) : theme.colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              'Select a track to play',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isDemoMode || isOfflineMode
                  ? 'Through the Fire and Flames included!'
                  : 'Only downloaded tracks are available',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: legendaryAvailable ? const Color(0xFFFF6B35) : Colors.white54,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _selectTrack,
              icon: Icon(legendaryAvailable ? Icons.local_fire_department : Icons.library_music),
              label: Text(legendaryAvailable ? 'CHOOSE TRACK' : 'CHOOSE TRACK'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                backgroundColor: legendaryAvailable ? const Color(0xFFFF6B35) : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnalyzing(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: theme.colorScheme.primary),
          const SizedBox(height: 24),
          Text(
            'Analyzing track...',
            style: theme.textTheme.titleLarge?.copyWith(color: Colors.white),
          ),
          const SizedBox(height: 16),
          ValueListenableBuilder<double>(
            valueListenable: _chartGenerator.progress,
            builder: (context, progress, _) {
              return Text(
                '${(progress * 100).toInt()}%',
                style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white54),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildReady(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _chart?.trackName ?? 'Unknown Track',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _chart?.artistName ?? 'Unknown Artist',
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _InfoChip(
                  icon: Icons.music_note,
                  label: '${_chart?.notes.length ?? 0} notes',
                ),
                const SizedBox(width: 16),
                _InfoChip(
                  icon: Icons.timer,
                  label: _chart?.formattedDuration ?? '0:00',
                ),
                const SizedBox(width: 16),
                _InfoChip(
                  icon: Icons.speed,
                  label: _chart?.formattedBpm ?? '-- BPM',
                ),
              ],
            ),
            if (_chart != null && _chart!.highScore > 0) ...[
              const SizedBox(height: 16),
              Text(
                'High Score: ${_chart!.formattedHighScore}',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: _backToSelect,
                  child: const Text('BACK'),
                ),
                const SizedBox(width: 16),
                ElevatedButton.icon(
                  onPressed: _startGame,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('START'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              Platform.isLinux || Platform.isMacOS || Platform.isWindows
                  ? 'Press 1-5 or F1-F5 to play'
                  : 'Tap the 5 lanes to hit notes',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaying(ThemeData theme) {
    // Fire colors for streak effects
    const fireOrange = Color(0xFFFF6B35);
    const fireRed = Color(0xFFFF4D6D);
    const fireYellow = Color(0xFFFFD700);
    const lightningBlue = Color(0xFF00BFFF);

    return Stack(
      children: [
        // Note highway
        _NoteHighway(
          chart: _chart!,
          currentTimeMs: _position.inMilliseconds,
          leadTimeMs: _noteLeadTime,
          lanePressed: _lanePressed,
          laneHitTime: _laneHitTime,
          primaryColor: theme.colorScheme.primary,
          onLaneTap: _onLaneTap,
          showStreakFire: _showStreakFire,
          combo: _combo,
          lightningLane: _lightningLane,
          particles: _particles,
          hitFeedbackText: _hitFeedbackText,
          hitFeedbackColor: _hitFeedbackColor,
          hitFeedbackTime: _hitFeedbackTime,
          hitFeedbackLane: _hitFeedbackLane,
        ),
        // Score display with Nautune font
        Positioned(
          top: MediaQuery.of(context).padding.top + 16,
          left: 16,
          right: 16,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SCORE',
                    style: GoogleFonts.raleway(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    _score.toString(),
                    style: GoogleFonts.raleway(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              // Combo with fire indicator
              Column(
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_showStreakFire) ...[
                        Icon(Icons.local_fire_department, color: fireOrange, size: 14),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        'COMBO',
                        style: GoogleFonts.raleway(
                          color: _showStreakFire ? fireOrange : Colors.white38,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    _combo.toString(),
                    style: GoogleFonts.raleway(
                      color: _showStreakFire ? fireYellow : theme.colorScheme.primary,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              // Animated multiplier with pulse
              AnimatedBuilder(
                animation: _multiplierPulse,
                builder: (context, child) {
                  final scale = _showStreakFire ? _multiplierPulse.value : 1.0;
                  return Transform.scale(
                    scale: scale,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        gradient: _showStreakFire
                            ? const LinearGradient(
                                colors: [fireRed, fireOrange],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              )
                            : null,
                        color: _showStreakFire ? null : theme.colorScheme.primary.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: _showStreakFire
                            ? [
                                BoxShadow(
                                  color: fireOrange.withValues(alpha: 0.5),
                                  blurRadius: 12,
                                  spreadRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_showStreakFire && _multiplier >= 4)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(
                                Icons.local_fire_department,
                                color: fireYellow,
                                size: 16,
                              ),
                            ),
                          Text(
                            '${_multiplier}x',
                            style: GoogleFonts.raleway(
                              color: _showStreakFire ? Colors.white : theme.colorScheme.primary,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        // Milestone flash overlay - stays visible for 70% of animation, then fades
        if (_milestoneText != null)
          AnimatedBuilder(
            animation: _milestoneFlash,
            builder: (context, child) {
              // Hold at full opacity for 70% of the animation, then fade out
              final progress = _milestoneFlash.value;
              final opacity = progress < 0.7
                  ? 1.0
                  : (1.0 - ((progress - 0.7) / 0.3)).clamp(0.0, 1.0);
              // Gentle scale: start at 1.0, grow slightly to 1.15
              final scale = 1.0 + (progress * 0.15);
              return Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Transform.scale(
                      scale: scale,
                      child: Opacity(
                        opacity: opacity,
                        child: Text(
                          _milestoneText!,
                          style: GoogleFonts.pacifico(
                            fontSize: 52,
                            color: fireYellow,
                            shadows: [
                              Shadow(
                                color: fireOrange,
                                blurRadius: 24,
                              ),
                              Shadow(
                                color: fireRed,
                                blurRadius: 48,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        // Active bonus indicator
        if (_activeBonus != null || _shieldCharges > 0)
          Positioned(
            top: MediaQuery.of(context).padding.top + 60,
            left: 16,
            child: _buildActiveBonusIndicator(fireOrange, fireYellow, lightningBlue),
          ),
        // Pause button
        Positioned(
          top: MediaQuery.of(context).padding.top + 8,
          right: 8,
          child: IconButton(
            icon: const Icon(Icons.pause, color: Colors.white54),
            onPressed: _pauseGame,
          ),
        ),
      ],
    );
  }

  Widget _buildActiveBonusIndicator(Color fireOrange, Color fireYellow, Color lightningBlue) {
    final remaining = _bonusExpiry != null
        ? _bonusExpiry!.difference(DateTime.now()).inMilliseconds / 1000.0
        : 0.0;

    Widget buildBonusChip(String label, IconData icon, Color color, {String? countdown}) {
      return Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 14),
            const SizedBox(width: 4),
            Text(
              countdown != null ? '$label $countdown' : label,
              style: GoogleFonts.raleway(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_activeBonus == BonusType.lightningLane)
          buildBonusChip('LIGHTNING', Icons.bolt, lightningBlue,
              countdown: '${remaining.toStringAsFixed(1)}s'),
        if (_activeBonus == BonusType.doublePoints)
          buildBonusChip('2X POINTS', Icons.double_arrow, fireYellow,
              countdown: '${remaining.toStringAsFixed(1)}s'),
        if (_activeBonus == BonusType.noteMagnet)
          buildBonusChip('MAGNET', Icons.track_changes, Colors.purple,
              countdown: '${remaining.toStringAsFixed(1)}s'),
        if (_shieldCharges > 0)
          buildBonusChip('SHIELD x$_shieldCharges', Icons.shield, Colors.cyan),
      ],
    );
  }

  Widget _buildPaused(ThemeData theme) {
    return Container(
      color: Colors.black87,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'PAUSED',
              style: theme.textTheme.headlineMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _resumeGame,
              icon: const Icon(Icons.play_arrow),
              label: const Text('RESUME'),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _endGame,
              child: const Text('QUIT'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEnded(ThemeData theme) {
    final totalNotes = _chart?.notes.length ?? 0;
    final accuracy = totalNotes > 0
        ? ((_perfectHits + _goodHits) / totalNotes * 100)
        : 0.0;

    String grade;
    if (accuracy >= 95) {
      grade = 'S';
    } else if (accuracy >= 90) {
      grade = 'A';
    } else if (accuracy >= 80) {
      grade = 'B';
    } else if (accuracy >= 70) {
      grade = 'C';
    } else if (accuracy >= 60) {
      grade = 'D';
    } else {
      grade = 'F';
    }

    final isNewHighScore = _chart != null && _score > _chart!.highScore;
    final isPerfect = _missedNotes == 0 && totalNotes > 0;

    // Fire colors
    const fireOrange = Color(0xFFFF6B35);
    const fireRed = Color(0xFFFF4D6D);
    const fireYellow = Color(0xFFFFD700);

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        gradient: _showLegendaryUnlock
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  fireRed.withValues(alpha: 0.3),
                  Colors.black,
                  fireOrange.withValues(alpha: 0.2),
                ],
              )
            : null,
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // LEGENDARY UNLOCK CELEBRATION
              if (_showLegendaryUnlock) ...[
                Icon(
                  Icons.local_fire_department,
                  color: fireYellow,
                  size: 64,
                ),
                const SizedBox(height: 8),
                Text(
                  'LEGENDARY UNLOCKED!',
                  style: GoogleFonts.pacifico(
                    color: fireYellow,
                    fontSize: 28,
                    shadows: [
                      Shadow(color: fireOrange, blurRadius: 20),
                      Shadow(color: fireRed, blurRadius: 40),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Through the Fire and Flames',
                  style: GoogleFonts.raleway(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'by DragonForce',
                  style: GoogleFonts.raleway(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'PERFECT SCORE ACHIEVED!',
                  style: GoogleFonts.raleway(
                    color: fireOrange,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() => _showLegendaryUnlock = false);
                    _prepareLegendaryTrack();
                  },
                  icon: const Icon(Icons.local_fire_department),
                  label: const Text('UNLOCK NOW'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: fireOrange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _showLegendaryUnlock = false),
                  child: const Text('Later', style: TextStyle(color: Colors.white54)),
                ),
                const SizedBox(height: 24),
                const Divider(color: Colors.white24),
                const SizedBox(height: 16),
              ],
              // Perfect score badge
              if (isPerfect && !_showLegendaryUnlock) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [fireRed, fireOrange]),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star, color: Colors.white, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'PERFECT!',
                        style: GoogleFonts.raleway(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              if (isNewHighScore && !_showLegendaryUnlock) ...[
                Text(
                  'NEW HIGH SCORE!',
                  style: GoogleFonts.raleway(
                    color: theme.colorScheme.primary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                grade,
                style: GoogleFonts.pacifico(
                  color: theme.colorScheme.primary,
                  fontSize: 80,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _score.toString(),
                style: GoogleFonts.raleway(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _StatColumn(label: 'Perfect', value: _perfectHits.toString()),
                  const SizedBox(width: 32),
                  _StatColumn(label: 'Good', value: _goodHits.toString()),
                  const SizedBox(width: 32),
                  _StatColumn(label: 'Missed', value: _missedNotes.toString()),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _StatColumn(label: 'Max Combo', value: _maxCombo.toString()),
                  const SizedBox(width: 32),
                  _StatColumn(label: 'Accuracy', value: '${accuracy.toStringAsFixed(1)}%'),
                  if (_bonusesCollected > 0) ...[
                    const SizedBox(width: 32),
                    _StatColumn(label: 'Bonuses', value: _bonusesCollected.toString()),
                  ],
                ],
              ),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: _backToSelect,
                    child: const Text('BACK'),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: _restartGame,
                    icon: const Icon(Icons.replay),
                    label: const Text('PLAY AGAIN'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum GameState {
  selectTrack,
  analyzing,
  ready,
  playing,
  paused,
  ended,
}

/// Particle effect for visual feedback
class _Particle {
  double x;
  double y;
  double vx;
  double vy;
  final Color color;
  final double size;
  final int lifetimeMs;
  final DateTime createdAt;
  double opacity;

  _Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.color,
    required this.size,
    required this.lifetimeMs,
    required this.createdAt,
  }) : opacity = 1.0;
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white54),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }
}

class _StatColumn extends StatelessWidget {
  final String label;
  final String value;

  const _StatColumn({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: GoogleFonts.raleway(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: GoogleFonts.raleway(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

/// Note highway widget - renders falling notes and hit zones
class _NoteHighway extends StatelessWidget {
  final ChartData chart;
  final int currentTimeMs;
  final int leadTimeMs;
  final List<bool> lanePressed;
  final List<DateTime?> laneHitTime;
  final Color primaryColor;
  final Function(int) onLaneTap;
  final bool showStreakFire;
  final int combo;
  final int? lightningLane;
  final List<_Particle> particles;
  final String? hitFeedbackText;
  final Color? hitFeedbackColor;
  final DateTime? hitFeedbackTime;
  final int? hitFeedbackLane;

  const _NoteHighway({
    required this.chart,
    required this.currentTimeMs,
    required this.leadTimeMs,
    required this.lanePressed,
    required this.laneHitTime,
    required this.primaryColor,
    required this.onLaneTap,
    this.showStreakFire = false,
    this.combo = 0,
    this.lightningLane,
    this.particles = const [],
    this.hitFeedbackText,
    this.hitFeedbackColor,
    this.hitFeedbackTime,
    this.hitFeedbackLane,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final laneWidth = constraints.maxWidth / 5; // 5 lanes
        // Scale hit line position for portrait mode (more room at bottom on narrow screens)
        final isPortrait = constraints.maxHeight > constraints.maxWidth;
        final hitLineOffset = isPortrait ? 100.0 : 120.0;
        final hitLineY = constraints.maxHeight - hitLineOffset;

        // Get visible notes
        final visibleNotes = <ChartNote>[];
        for (final note in chart.notes) {
          if (note.timestampMs >= currentTimeMs - 100 &&
              note.timestampMs <= currentTimeMs + leadTimeMs) {
            visibleNotes.add(note);
          }
          if (note.timestampMs > currentTimeMs + leadTimeMs) break;
        }

        return GestureDetector(
          onTapDown: (details) {
            final lane = (details.localPosition.dx / laneWidth).floor().clamp(0, 4);
            onLaneTap(lane);
          },
          child: CustomPaint(
            painter: _NoteHighwayPainter(
              notes: visibleNotes,
              currentTimeMs: currentTimeMs,
              leadTimeMs: leadTimeMs,
              hitLineY: hitLineY,
              laneWidth: laneWidth,
              lanePressed: lanePressed,
              laneHitTime: laneHitTime,
              primaryColor: primaryColor,
              showStreakFire: showStreakFire,
              combo: combo,
              lightningLane: lightningLane,
              particles: particles,
              hitFeedbackText: hitFeedbackText,
              hitFeedbackColor: hitFeedbackColor,
              hitFeedbackTime: hitFeedbackTime,
              hitFeedbackLane: hitFeedbackLane,
            ),
            size: Size(constraints.maxWidth, constraints.maxHeight),
          ),
        );
      },
    );
  }
}

class _NoteHighwayPainter extends CustomPainter {
  final List<ChartNote> notes;
  final int currentTimeMs;
  final int leadTimeMs;
  final double hitLineY;
  final double laneWidth;
  final List<bool> lanePressed;
  final List<DateTime?> laneHitTime;
  final Color primaryColor;
  final bool showStreakFire;
  final int combo;
  final int? lightningLane;
  final List<_Particle> particles;
  final String? hitFeedbackText;
  final Color? hitFeedbackColor;
  final DateTime? hitFeedbackTime;
  final int? hitFeedbackLane;

  _NoteHighwayPainter({
    required this.notes,
    required this.currentTimeMs,
    required this.leadTimeMs,
    required this.hitLineY,
    required this.laneWidth,
    required this.lanePressed,
    required this.laneHitTime,
    required this.primaryColor,
    this.showStreakFire = false,
    this.combo = 0,
    this.lightningLane,
    this.particles = const [],
    this.hitFeedbackText,
    this.hitFeedbackColor,
    this.hitFeedbackTime,
    this.hitFeedbackLane,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Generate lane colors from theme primary using hue shifts
    // Creates a rainbow spread around the primary color
    final baseHsl = HSLColor.fromColor(primaryColor);
    final laneColors = [
      baseHsl.withHue((baseHsl.hue - 60) % 360).withSaturation(0.9).withLightness(0.5).toColor(),  // Lane 0
      baseHsl.withHue((baseHsl.hue - 30) % 360).withSaturation(0.9).withLightness(0.5).toColor(),  // Lane 1
      baseHsl.withSaturation(0.9).withLightness(0.55).toColor(),                                    // Lane 2 - Primary
      baseHsl.withHue((baseHsl.hue + 30) % 360).withSaturation(0.9).withLightness(0.5).toColor(),  // Lane 3
      baseHsl.withHue((baseHsl.hue + 60) % 360).withSaturation(0.9).withLightness(0.5).toColor(),  // Lane 4
    ];

    // Scale sizes based on lane width for iOS portrait mode
    // On narrow screens (portrait), elements scale down proportionally
    final isPortrait = size.height > size.width;
    final scaleFactor = isPortrait ? (laneWidth / 80.0).clamp(0.6, 1.0) : 1.0;
    final noteRadius = 10.0 * scaleFactor;
    final noteGlowRadius = 14.0 * scaleFactor;
    final highlightRadius = 3.0 * scaleFactor;
    final highlightOffset = 3.0 * scaleFactor;
    final zoneHeight = 40.0 * scaleFactor;
    final zonePadding = 2.0 * scaleFactor;
    final zoneCornerRadius = 8.0 * scaleFactor;
    final flashRadius = 20.0 * scaleFactor;

    // Draw lane dividers
    final lanePaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;

    for (int i = 1; i < 5; i++) {
      canvas.drawLine(
        Offset(i * laneWidth, 0),
        Offset(i * laneWidth, size.height),
        lanePaint,
      );
    }

    // Draw hit line (with fire effect when on streak)
    final hitLinePaint = Paint()
      ..color = showStreakFire
          ? const Color(0xFFFF6B35).withValues(alpha: 0.9) // Fire orange
          : primaryColor.withValues(alpha: 0.8)
      ..strokeWidth = showStreakFire ? 4 : 3;
    canvas.drawLine(
      Offset(0, hitLineY),
      Offset(size.width, hitLineY),
      hitLinePaint,
    );

    // Streak fire glow effect on hit line
    if (showStreakFire) {
      final fireIntensity = (combo / 50.0).clamp(0.3, 1.0);
      final fireGlowPaint = Paint()
        ..color = const Color(0xFFFF6B35).withValues(alpha: 0.3 * fireIntensity)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 15 * scaleFactor);
      canvas.drawLine(
        Offset(0, hitLineY),
        Offset(size.width, hitLineY),
        fireGlowPaint..strokeWidth = 20,
      );

      // Secondary yellow glow for higher combos
      if (combo >= 20) {
        final yellowGlowPaint = Paint()
          ..color = const Color(0xFFFFD700).withValues(alpha: 0.2 * fireIntensity)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 25 * scaleFactor);
        canvas.drawLine(
          Offset(0, hitLineY),
          Offset(size.width, hitLineY),
          yellowGlowPaint..strokeWidth = 30,
        );
      }
    }

    // Draw hit zones for 5 frets
    for (int lane = 0; lane < 5; lane++) {
      final isPressed = lanePressed[lane];
      final hitTime = laneHitTime[lane];
      final isRecentHit = hitTime != null &&
          DateTime.now().difference(hitTime).inMilliseconds < 150;

      final zoneRect = Rect.fromLTWH(
        lane * laneWidth + zonePadding,
        hitLineY - zoneHeight / 2,
        laneWidth - zonePadding * 2,
        zoneHeight,
      );

      final zonePaint = Paint()
        ..color = isPressed || isRecentHit
            ? laneColors[lane].withValues(alpha: 0.5)
            : laneColors[lane].withValues(alpha: 0.2);

      canvas.drawRRect(
        RRect.fromRectAndRadius(zoneRect, Radius.circular(zoneCornerRadius)),
        zonePaint,
      );

      // Hit flash effect
      if (isRecentHit) {
        final flashPaint = Paint()
          ..color = Colors.white.withValues(alpha: 0.4)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 15 * scaleFactor);
        canvas.drawCircle(
          Offset(lane * laneWidth + laneWidth / 2, hitLineY),
          flashRadius,
          flashPaint,
        );
      }
    }

    // Draw lightning lane effect
    if (lightningLane != null) {
      final lightningPaint = Paint()
        ..color = const Color(0xFF00BFFF).withValues(alpha: 0.15)
        ..style = PaintingStyle.fill;
      canvas.drawRect(
        Rect.fromLTWH(lightningLane! * laneWidth, 0, laneWidth, size.height),
        lightningPaint,
      );

      // Lightning bolt line down the center
      final boltPaint = Paint()
        ..color = const Color(0xFF00BFFF).withValues(alpha: 0.6)
        ..strokeWidth = 3
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 * scaleFactor);
      final boltX = lightningLane! * laneWidth + laneWidth / 2;
      canvas.drawLine(Offset(boltX, 0), Offset(boltX, hitLineY), boltPaint);
    }

    // Draw notes
    final notePaint = Paint()..style = PaintingStyle.fill;
    final noteGlowPaint = Paint()
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 * scaleFactor);

    for (final note in notes) {
      // Clamp lane to valid range (0-4)
      final lane = note.lane.clamp(0, 4);
      final progress = (note.timestampMs - currentTimeMs) / leadTimeMs;
      final noteY = hitLineY - (progress * hitLineY);
      final noteX = lane * laneWidth + laneWidth / 2;

      if (note.isBonus) {
        // Golden bonus note
        const bonusGold = Color(0xFFFFD700);
        const bonusOrange = Color(0xFFFF8C00);

        // Larger glow for bonus
        noteGlowPaint.color = bonusGold.withValues(alpha: 0.6);
        canvas.drawCircle(Offset(noteX, noteY), noteGlowRadius * 1.8, noteGlowPaint);

        // Star shape or diamond for bonus
        notePaint.color = bonusGold;
        canvas.drawCircle(Offset(noteX, noteY), noteRadius * 1.4, notePaint);

        // Inner glow
        notePaint.color = bonusOrange;
        canvas.drawCircle(Offset(noteX, noteY), noteRadius * 0.8, notePaint);

        // Sparkle highlight
        notePaint.color = Colors.white.withValues(alpha: 0.8);
        canvas.drawCircle(Offset(noteX - highlightOffset * 1.5, noteY - highlightOffset * 1.5), highlightRadius * 1.2, notePaint);
      } else {
        final color = laneColors[lane];

        // Glow
        noteGlowPaint.color = color.withValues(alpha: 0.4);
        canvas.drawCircle(Offset(noteX, noteY), noteGlowRadius, noteGlowPaint);

        // Note (scales for portrait mode)
        notePaint.color = color;
        canvas.drawCircle(Offset(noteX, noteY), noteRadius, notePaint);

        // Inner highlight
        notePaint.color = Colors.white.withValues(alpha: 0.4);
        canvas.drawCircle(Offset(noteX - highlightOffset, noteY - highlightOffset), highlightRadius, notePaint);
      }
    }

    // Draw particles
    for (final particle in particles) {
      final particlePaint = Paint()
        ..color = particle.color.withValues(alpha: particle.opacity)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        Offset(particle.x * size.width, particle.y * size.height),
        particle.size,
        particlePaint,
      );
    }

    // Draw hit feedback text
    if (hitFeedbackText != null && hitFeedbackTime != null && hitFeedbackLane != null) {
      final age = DateTime.now().difference(hitFeedbackTime!).inMilliseconds;
      if (age < 400) {
        final opacity = 1.0 - (age / 400.0);
        final yOffset = age * 0.08; // Float upward

        final textPainter = TextPainter(
          text: TextSpan(
            text: hitFeedbackText,
            style: TextStyle(
              color: (hitFeedbackColor ?? Colors.white).withValues(alpha: opacity),
              fontSize: 16 * scaleFactor,
              fontWeight: FontWeight.bold,
              shadows: [
                Shadow(
                  color: Colors.black.withValues(alpha: opacity * 0.5),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();

        final feedbackX = hitFeedbackLane! * laneWidth + laneWidth / 2 - textPainter.width / 2;
        final feedbackY = hitLineY - 50 - yOffset;
        textPainter.paint(canvas, Offset(feedbackX, feedbackY));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _NoteHighwayPainter old) => true;
}

/// Track selection dialog with album art
class _TrackSelectionDialog extends StatelessWidget {
  final List<DownloadItem> downloads;
  final bool legendaryReady;
  final String? legendaryPath;
  final String legendaryTrackName;
  final String legendaryArtistName;
  final String legendaryTrackId;
  final bool isDemoMode;

  const _TrackSelectionDialog({
    required this.downloads,
    this.legendaryReady = false,
    this.legendaryPath,
    this.legendaryTrackName = '',
    this.legendaryArtistName = '',
    this.legendaryTrackId = '',
    this.isDemoMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalItems = downloads.length + (legendaryReady ? 1 : 0);

    return AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      title: Row(
        children: [
          Icon(Icons.local_fire_department, color: theme.colorScheme.primary, size: 24),
          const SizedBox(width: 12),
          Text('Select Track', style: TextStyle(color: theme.colorScheme.onSurface)),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: ListView.builder(
          itemCount: totalItems,
          itemBuilder: (context, index) {
            // Show legendary track at the top if available
            if (legendaryReady && index == 0) {
              return _buildLegendaryTrackItem(context, theme);
            }

            final downloadIndex = legendaryReady ? index - 1 : index;
            final item = downloads[downloadIndex];
            final track = item.track;

            // Get album art info
            final hasAlbumArt = track.albumId != null && track.albumPrimaryImageTag != null;

            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.pop(context, {
                      'path': item.localPath,
                      'id': track.id,
                      'name': track.name,
                      'artist': track.artists.isNotEmpty ? track.artists.first : 'Unknown Artist',
                      'duration': track.runTimeTicks != null
                          ? (track.runTimeTicks! ~/ 10000).toString()
                          : '180000',
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        // Album art
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 56,
                            height: 56,
                            child: hasAlbumArt
                                ? JellyfinImage(
                                    itemId: track.albumId!,
                                    imageTag: track.albumPrimaryImageTag,
                                    trackId: track.id,
                                    width: 56,
                                    height: 56,
                                    errorBuilder: (context, url, error) => Container(
                                      color: theme.colorScheme.surfaceContainerHighest,
                                      child: Icon(
                                        Icons.album,
                                        color: theme.colorScheme.primary.withValues(alpha: 0.5),
                                        size: 28,
                                      ),
                                    ),
                                  )
                                : Container(
                                    color: theme.colorScheme.surfaceContainerHighest,
                                    child: Icon(
                                      Icons.album,
                                      color: theme.colorScheme.primary.withValues(alpha: 0.5),
                                      size: 28,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Track info
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                track.name,
                                style: TextStyle(
                                  color: theme.colorScheme.onSurface,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                track.artists.isNotEmpty ? track.artists.first : 'Unknown Artist',
                                style: TextStyle(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                                  fontSize: 13,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (track.album != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  track.album!,
                                  style: TextStyle(
                                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                        // Play icon
                        Icon(
                          Icons.play_circle_outline,
                          color: theme.colorScheme.primary,
                          size: 28,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
      ],
    );
  }

  Widget _buildLegendaryTrackItem(BuildContext context, ThemeData theme) {
    const fireOrange = Color(0xFFFF6B35);
    const fireYellow = Color(0xFFFFD700);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            Navigator.pop(context, {
              'path': legendaryPath ?? '',
              'id': legendaryTrackId,
              'name': legendaryTrackName,
              'artist': legendaryArtistName,
              'duration': '442000', // ~7:22 for TTFAF
            });
          },
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  fireOrange.withValues(alpha: 0.2),
                  Colors.transparent,
                ],
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: fireOrange.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                // Fire icon as album art
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [fireOrange, Color(0xFFFF4D6D)],
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.local_fire_department,
                    color: fireYellow,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 12),
                // Track info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.star, color: fireYellow, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            'LEGENDARY',
                            style: GoogleFonts.raleway(
                              color: fireYellow,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        legendaryTrackName,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        legendaryArtistName,
                        style: TextStyle(
                          color: fireOrange,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // Fire play icon
                Icon(
                  Icons.local_fire_department,
                  color: fireOrange,
                  size: 28,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
