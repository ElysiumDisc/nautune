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

  // Smart caching settings
  int _preCacheTrackCount = 3;  // 0 = off, 3, 5, or 10
  bool _wifiOnlyCaching = false;

  // Download settings
  int _maxConcurrentDownloads = 3;
  bool _wifiOnlyDownloads = false;
  int _storageLimitMB = 0;
  bool _autoCleanupEnabled = false;
  int _autoCleanupDays = 30;

  // Getters
  bool get showVolumeBar => _showVolumeBar;
  bool get crossfadeEnabled => _crossfadeEnabled;
  int get crossfadeDurationSeconds => _crossfadeDurationSeconds;
  bool get infiniteRadioEnabled => _infiniteRadioEnabled;
  int get cacheTtlMinutes => _cacheTtlMinutes;
  int get libraryTabIndex => _libraryTabIndex;
  double? getScrollOffset(String key) => _scrollOffsets[key];

  // Smart caching getters
  int get preCacheTrackCount => _preCacheTrackCount;
  bool get wifiOnlyCaching => _wifiOnlyCaching;

  // Download settings getters
  int get maxConcurrentDownloads => _maxConcurrentDownloads;
  bool get wifiOnlyDownloads => _wifiOnlyDownloads;
  int get storageLimitMB => _storageLimitMB;
  bool get autoCleanupEnabled => _autoCleanupEnabled;
  int get autoCleanupDays => _autoCleanupDays;

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

        // Smart caching settings
        _preCacheTrackCount = storedPlaybackState.preCacheTrackCount;
        _wifiOnlyCaching = storedPlaybackState.wifiOnlyCaching;

        // Download settings
        _maxConcurrentDownloads = storedPlaybackState.maxConcurrentDownloads;
        _wifiOnlyDownloads = storedPlaybackState.wifiOnlyDownloads;
        _storageLimitMB = storedPlaybackState.storageLimitMB;
        _autoCleanupEnabled = storedPlaybackState.autoCleanupEnabled;
        _autoCleanupDays = storedPlaybackState.autoCleanupDays;

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

  /// Set cache TTL in minutes (1-10080).
  /// Higher = faster browsing, Lower = fresher data.
  void setCacheTtl(int minutes) {
    _cacheTtlMinutes = minutes.clamp(1, 10080);
    unawaited(_playbackStateStore.saveUiState(
      cacheTtlMinutes: _cacheTtlMinutes,
    ));
    notifyListeners();
  }

  /// Set pre-cache track count (0 = off, 3, 5, or 10).
  /// Pre-caches upcoming tracks for smoother playback.
  void setPreCacheTrackCount(int count) {
    _preCacheTrackCount = count;
    unawaited(_playbackStateStore.saveUiState(
      preCacheTrackCount: count,
    ));
    notifyListeners();
  }

  /// Set WiFi-only caching.
  /// When enabled, only pre-caches tracks when connected to WiFi.
  void setWifiOnlyCaching(bool value) {
    _wifiOnlyCaching = value;
    unawaited(_playbackStateStore.saveUiState(
      wifiOnlyCaching: value,
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

  // Download settings setters

  /// Set max concurrent downloads (1-10).
  void setMaxConcurrentDownloads(int value) {
    _maxConcurrentDownloads = value.clamp(1, 10);
    unawaited(_playbackStateStore.saveUiState(
      maxConcurrentDownloads: _maxConcurrentDownloads,
    ));
    notifyListeners();
  }

  /// Set WiFi-only downloads.
  void setWifiOnlyDownloads(bool value) {
    _wifiOnlyDownloads = value;
    unawaited(_playbackStateStore.saveUiState(
      wifiOnlyDownloads: value,
    ));
    notifyListeners();
  }

  /// Set storage limit in MB (0 = unlimited).
  void setStorageLimitMB(int value) {
    _storageLimitMB = value;
    unawaited(_playbackStateStore.saveUiState(
      storageLimitMB: value,
    ));
    notifyListeners();
  }

  /// Set auto-cleanup settings.
  void setAutoCleanup({bool? enabled, int? days}) {
    if (enabled != null) _autoCleanupEnabled = enabled;
    if (days != null) _autoCleanupDays = days;
    unawaited(_playbackStateStore.saveUiState(
      autoCleanupEnabled: _autoCleanupEnabled,
      autoCleanupDays: _autoCleanupDays,
    ));
    notifyListeners();
  }
}
