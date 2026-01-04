import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/playback_state_store.dart';

/// Manages UI-only state that doesn't affect data or business logic.
///
/// Responsibilities:
/// - Volume bar visibility
/// - Crossfade settings
/// - Infinite Radio mode
/// - Cache TTL settings
/// - Library tab index
/// - Scroll positions
/// - UI preferences persistence
///
/// This provider is completely independent from:
/// - Session state (SessionProvider)
/// - Library data (LibraryDataProvider)
/// - Audio playback state (AudioPlayerService)
///
/// By isolating UI state, we ensure that toggling the volume bar
/// only rebuilds UI-dependent widgets, not the entire app.
class UIStateProvider extends ChangeNotifier {
  UIStateProvider({
    required PlaybackStateStore playbackStateStore,
  }) : _playbackStateStore = playbackStateStore;

  final PlaybackStateStore _playbackStateStore;

  bool _showVolumeBar = true;
  bool _crossfadeEnabled = false;
  int _crossfadeDurationSeconds = 3;
  bool _infiniteRadioEnabled = false;
  int _cacheTtlMinutes = 2;
  int _libraryTabIndex = 0;
  Map<String, double> _scrollOffsets = {};

  // Getters
  bool get showVolumeBar => _showVolumeBar;
  bool get crossfadeEnabled => _crossfadeEnabled;
  int get crossfadeDurationSeconds => _crossfadeDurationSeconds;
  bool get infiniteRadioEnabled => _infiniteRadioEnabled;
  int get cacheTtlMinutes => _cacheTtlMinutes;
  int get libraryTabIndex => _libraryTabIndex;
  double? getScrollOffset(String key) => _scrollOffsets[key];

  /// Initialize UI state by loading persisted preferences.
  ///
  /// This should be called once during app startup.
  Future<void> initialize() async {
    debugPrint('UIStateProvider: Initializing...');

    try {
      final storedPlaybackState = await _playbackStateStore.load();
      if (storedPlaybackState != null) {
        _showVolumeBar = storedPlaybackState.showVolumeBar;
        _crossfadeEnabled = storedPlaybackState.crossfadeEnabled;
        _crossfadeDurationSeconds = storedPlaybackState.crossfadeDurationSeconds;
        _infiniteRadioEnabled = storedPlaybackState.infiniteRadioEnabled;
        _cacheTtlMinutes = storedPlaybackState.cacheTtlMinutes;
        _libraryTabIndex = storedPlaybackState.libraryTabIndex;
        _scrollOffsets = Map<String, double>.from(storedPlaybackState.scrollOffsets);

        debugPrint('UIStateProvider: Restored UI preferences');
        notifyListeners();
      }
    } catch (error) {
      debugPrint('UIStateProvider: Failed to load UI state: $error');
    }
  }

  /// Toggle volume bar visibility.
  void toggleVolumeBar() {
    _showVolumeBar = !_showVolumeBar;
    unawaited(_playbackStateStore.saveUiState(showVolumeBar: _showVolumeBar));
    notifyListeners();
  }

  /// Set volume bar visibility.
  void setVolumeBarVisibility(bool visible) {
    if (_showVolumeBar == visible) return;
    _showVolumeBar = visible;
    unawaited(_playbackStateStore.saveUiState(showVolumeBar: _showVolumeBar));
    notifyListeners();
  }

  /// Toggle crossfade on/off.
  void toggleCrossfade(bool enabled) {
    _crossfadeEnabled = enabled;
    unawaited(_playbackStateStore.saveUiState(
      crossfadeEnabled: enabled,
      crossfadeDurationSeconds: _crossfadeDurationSeconds,
    ));
    notifyListeners();
  }

  /// Set crossfade duration in seconds (clamped to 0-10).
  void setCrossfadeDuration(int seconds) {
    _crossfadeDurationSeconds = seconds.clamp(0, 10);
    unawaited(_playbackStateStore.saveUiState(
      crossfadeEnabled: _crossfadeEnabled,
      crossfadeDurationSeconds: _crossfadeDurationSeconds,
    ));
    notifyListeners();
  }

  /// Toggle infinite radio mode on/off.
  /// When enabled, new tracks are auto-generated when queue runs low.
  void toggleInfiniteRadio(bool enabled) {
    _infiniteRadioEnabled = enabled;
    unawaited(_playbackStateStore.saveUiState(
      infiniteRadioEnabled: enabled,
    ));
    notifyListeners();
  }

  /// Set cache TTL in minutes (1-30).
  /// Higher = faster browsing, Lower = fresher data.
  void setCacheTtl(int minutes) {
    _cacheTtlMinutes = minutes.clamp(1, 30);
    unawaited(_playbackStateStore.saveUiState(
      cacheTtlMinutes: _cacheTtlMinutes,
    ));
    notifyListeners();
  }

  /// Update the active library tab index.
  void updateLibraryTabIndex(int index) {
    if (_libraryTabIndex == index) return;
    _libraryTabIndex = index;
    unawaited(_playbackStateStore.saveUiState(libraryTabIndex: index));
    notifyListeners();
  }

  /// Update scroll offset for a specific scrollable area.
  ///
  /// [key] is a unique identifier for the scrollable area (e.g., 'albums_grid', 'artists_list')
  void updateScrollOffset(String key, double offset) {
    _scrollOffsets[key] = offset;
    unawaited(
      _playbackStateStore.saveUiState(scrollOffsets: {key: offset}),
    );
    // Don't notify listeners for scroll updates - they're too frequent
    // Widgets should read the value when needed, not rebuild on every scroll pixel
  }
}
