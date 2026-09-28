import 'dart:async';

import 'package:flutter/foundation.dart';

import '../jellyfin/jellyfin_service.dart';
import '../utils/collection_sort.dart';
import '../services/playback_state_store.dart';

/// Manages UI-only state that doesn't affect data or business logic.
///
/// Responsibilities:
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
/// Volume bar, crossfade and Infinite Radio are owned by NautuneAppState
/// (it both persists them and applies them to the audio service); they were
/// removed here to avoid a second, disconnected source of truth.
class UIStateProvider extends ChangeNotifier {
  UIStateProvider({
    required PlaybackStateStore playbackStateStore,
    JellyfinService? jellyfinService,
  })  : _playbackStateStore = playbackStateStore,
        _jellyfinService = jellyfinService;

  final PlaybackStateStore _playbackStateStore;

  /// Service whose in-memory library cache honours [cacheTtlMinutes]. When
  /// provided, the TTL is applied on [initialize] and on every
  /// [setCacheTtl], so this provider alone keeps the service in sync (no
  /// need for callers to also go through NautuneAppState).
  final JellyfinService? _jellyfinService;

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

  // Grid size (2-6 columns per row)
  int _gridSize = 2;

  // List mode (true = list view, false = grid view)
  bool _useListMode = false;

  // Client-side sort orders
  FavoritesSort _favoritesSort = FavoritesSort.recent;
  PlaylistSort _playlistSort = PlaylistSort.recent;
  FavoritesSort get favoritesSort => _favoritesSort;
  PlaylistSort get playlistSort => _playlistSort;

  void setFavoritesSort(FavoritesSort sort) {
    if (_favoritesSort == sort) return;
    _favoritesSort = sort;
    unawaited(_playbackStateStore.saveUiState(favoritesSort: sort.name));
    notifyListeners();
  }

  void setPlaylistSort(PlaylistSort sort) {
    if (_playlistSort == sort) return;
    _playlistSort = sort;
    unawaited(_playbackStateStore.saveUiState(playlistSort: sort.name));
    notifyListeners();
  }

  // Getters
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

  // Grid size getter
  int get gridSize => _gridSize;

  // List mode getter
  bool get useListMode => _useListMode;

  /// Initialize UI state by loading persisted preferences.
  ///
  /// This should be called once during app startup.
  Future<void> initialize() async {
    debugPrint('UIStateProvider: Initializing...');

    try {
      final storedPlaybackState = await _playbackStateStore.load();
      if (storedPlaybackState != null) {
        _cacheTtlMinutes = storedPlaybackState.cacheTtlMinutes.clamp(1, 10080);
        _applyCacheTtl();
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

        // Grid size
        _gridSize = storedPlaybackState.gridSize;

        // List mode
        _useListMode = storedPlaybackState.useListMode;
        _favoritesSort = FavoritesSort.fromName(storedPlaybackState.favoritesSort);
        _playlistSort = PlaylistSort.fromName(storedPlaybackState.playlistSort);

        debugPrint('UIStateProvider: Restored UI preferences');
        notifyListeners();
      }
    } catch (error) {
      debugPrint('UIStateProvider: Failed to load UI state: $error');
    }
  }

  /// Set cache TTL in minutes (1-10080).
  /// Higher = faster browsing, Lower = fresher data.
  void setCacheTtl(int minutes) {
    _cacheTtlMinutes = minutes.clamp(1, 10080);
    _applyCacheTtl();
    unawaited(_playbackStateStore.saveUiState(
      cacheTtlMinutes: _cacheTtlMinutes,
    ));
    notifyListeners();
  }

  void _applyCacheTtl() {
    _jellyfinService?.setCacheTtl(Duration(minutes: _cacheTtlMinutes));
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

  /// Set grid size for album/artist views (2-6 columns per row).
  void setGridSize(int size) {
    final clampedSize = size.clamp(2, 6);
    if (_gridSize == clampedSize) return;
    _gridSize = clampedSize;
    unawaited(_playbackStateStore.saveUiState(gridSize: clampedSize));
    notifyListeners();
  }

  /// Toggle between list mode and grid mode.
  void setUseListMode(bool value) {
    if (_useListMode == value) return;
    _useListMode = value;
    unawaited(_playbackStateStore.saveUiState(useListMode: value));
    notifyListeners();
  }

  @override
  void dispose() {
    _scrollOffsets.clear();
    super.dispose();
  }
}
