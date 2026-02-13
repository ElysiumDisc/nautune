import '../jellyfin/jellyfin_track.dart';
import 'now_playing_layout.dart';
import 'visualizer_type.dart';

/// Streaming quality options for audio playback
enum StreamingQuality {
  original, // Direct stream, no transcoding (lossless)
  high,     // 320kbps
  normal,   // 192kbps
  low,      // 128kbps
  auto,     // Original on WiFi, Normal on cellular
}

extension StreamingQualityExtension on StreamingQuality {
  String get label {
    switch (this) {
      case StreamingQuality.original:
        return 'Original';
      case StreamingQuality.high:
        return 'High (320k)';
      case StreamingQuality.normal:
        return 'Normal (192k)';
      case StreamingQuality.low:
        return 'Low (128k)';
      case StreamingQuality.auto:
        return 'Auto';
    }
  }

  /// Returns the max bitrate in bps, or null for original/direct stream
  int? get maxBitrate {
    switch (this) {
      case StreamingQuality.original:
        return null; // Direct stream, no transcoding
      case StreamingQuality.high:
        return 320000;
      case StreamingQuality.normal:
        return 192000;
      case StreamingQuality.low:
        return 128000;
      case StreamingQuality.auto:
        return null; // Determined at runtime
    }
  }

  static StreamingQuality fromString(String? value) {
    switch (value) {
      case 'original':
        return StreamingQuality.original;
      case 'high':
        return StreamingQuality.high;
      case 'normal':
        return StreamingQuality.normal;
      case 'low':
        return StreamingQuality.low;
      case 'auto':
        return StreamingQuality.auto;
      default:
        return StreamingQuality.original; // Default to lossless
    }
  }
}

class PlaybackState {
  PlaybackState({
    this.currentTrackId,
    this.currentTrackName,
    this.currentAlbumId,
    this.currentAlbumName,
    this.positionMs = 0,
    this.isPlaying = false,
    this.queueIds = const [],
    this.queueSnapshot = const [],
    this.currentQueueIndex = 0,
    this.repeatMode = 'off',
    this.shuffleEnabled = false,
    this.volume = 1.0,
    this.scrollOffsets = const <String, double>{},
    this.libraryTabIndex = 0,
    this.showVolumeBar = true,
    this.crossfadeEnabled = false,
    this.crossfadeDurationSeconds = 3,
    this.infiniteRadioEnabled = false,
    this.cacheTtlMinutes = 2,
    this.gaplessPlaybackEnabled = true,
    // Download settings
    this.maxConcurrentDownloads = 3,
    this.wifiOnlyDownloads = false,
    this.storageLimitMB = 0, // 0 = unlimited
    this.autoCleanupEnabled = false,
    this.autoCleanupDays = 30,
    // Streaming quality
    this.streamingQuality = StreamingQuality.original,
    // Theme
    this.themePaletteId = 'purple_ocean',
    this.customPrimaryColor,  // Custom theme primary color (stored as int)
    this.customSecondaryColor,  // Custom theme secondary color (stored as int)
    this.customAccentColor,  // Custom theme accent color (stored as int)
    this.customThemeIsLight = false,  // Whether custom theme is light mode
    // Visualizer
    this.visualizerEnabled = true,
    this.visualizerType = VisualizerType.bioluminescent,
    this.visualizerPosition = VisualizerPosition.controlsBar,
    // Smart caching
    this.preCacheTrackCount = 3,  // 0 = off, 3, 5, or 10
    this.wifiOnlyCaching = false,
    // Offline mode
    this.isOfflineMode = false,
    // Submarine Mode (battery saver)
    this.submarineModeEnabled = false,
    this.batterySaverSnapshot,
    // Grid size (2 = compact, 3 = normal, 4 = large)
    this.gridSize = 2,
    // List mode vs grid mode
    this.useListMode = false,
    // Now Playing layout
    this.nowPlayingLayout = NowPlayingLayout.classic,
    // Nav tab order
    this.navTabOrder = const [0, 1, 2, 3, 4],
  });

  final String? currentTrackId;
  final String? currentTrackName;
  final String? currentAlbumId;
  final String? currentAlbumName;
  final int positionMs;
  final bool isPlaying;
  final List<String> queueIds;
  final List<Map<String, dynamic>> queueSnapshot;
  final int currentQueueIndex;
  final String repeatMode;
  final bool shuffleEnabled;
  final double volume;
  final Map<String, double> scrollOffsets;
  final int libraryTabIndex;
  final bool showVolumeBar;
  final bool crossfadeEnabled;
  final int crossfadeDurationSeconds;
  final bool infiniteRadioEnabled;
  final int cacheTtlMinutes;
  final bool gaplessPlaybackEnabled;
  // Download settings
  final int maxConcurrentDownloads;
  final bool wifiOnlyDownloads;
  final int storageLimitMB; // 0 = unlimited
  final bool autoCleanupEnabled;
  final int autoCleanupDays;
  // Streaming quality
  final StreamingQuality streamingQuality;
  // Theme
  final String themePaletteId;
  final int? customPrimaryColor;  // Custom theme primary (Color.value)
  final int? customSecondaryColor;  // Custom theme secondary (Color.value)
  final int? customAccentColor;  // Custom theme accent (Color.value)
  final bool customThemeIsLight;  // Whether custom theme is light
  // Visualizer
  final bool visualizerEnabled;
  final VisualizerType visualizerType;
  final VisualizerPosition visualizerPosition;
  // Smart caching
  final int preCacheTrackCount;  // 0 = off, 3, 5, or 10
  final bool wifiOnlyCaching;
  // Offline mode
  final bool isOfflineMode;
  // Submarine Mode (battery saver)
  final bool submarineModeEnabled;
  final Map<String, dynamic>? batterySaverSnapshot;
  // Grid size (2 = compact, 3 = normal, 4 = large)
  final int gridSize;
  // List mode vs grid mode
  final bool useListMode;
  // Now Playing layout
  final NowPlayingLayout nowPlayingLayout;
  // Nav tab order
  final List<int> navTabOrder;

  bool get hasTrack => currentTrackId != null;

  PlaybackState copyWith({
    String? currentTrackId,
    String? currentTrackName,
    String? currentAlbumId,
    String? currentAlbumName,
    int? positionMs,
    bool? isPlaying,
    List<String>? queueIds,
    List<Map<String, dynamic>>? queueSnapshot,
    int? currentQueueIndex,
    String? repeatMode,
    bool? shuffleEnabled,
    double? volume,
    Map<String, double>? scrollOffsets,
    int? libraryTabIndex,
    bool? showVolumeBar,
    bool? crossfadeEnabled,
    int? crossfadeDurationSeconds,
    bool? infiniteRadioEnabled,
    int? cacheTtlMinutes,
    bool? gaplessPlaybackEnabled,
    int? maxConcurrentDownloads,
    bool? wifiOnlyDownloads,
    int? storageLimitMB,
    bool? autoCleanupEnabled,
    int? autoCleanupDays,
    StreamingQuality? streamingQuality,
    String? themePaletteId,
    int? customPrimaryColor,
    int? customSecondaryColor,
    int? customAccentColor,
    bool? customThemeIsLight,
    bool? visualizerEnabled,
    VisualizerType? visualizerType,
    VisualizerPosition? visualizerPosition,
    int? preCacheTrackCount,
    bool? wifiOnlyCaching,
    bool? isOfflineMode,
    bool? submarineModeEnabled,
    Map<String, dynamic>? batterySaverSnapshot,
    int? gridSize,
    bool? useListMode,
    NowPlayingLayout? nowPlayingLayout,
    List<int>? navTabOrder,
  }) {
    return PlaybackState(
      currentTrackId: currentTrackId ?? this.currentTrackId,
      currentTrackName: currentTrackName ?? this.currentTrackName,
      currentAlbumId: currentAlbumId ?? this.currentAlbumId,
      currentAlbumName: currentAlbumName ?? this.currentAlbumName,
      positionMs: positionMs ?? this.positionMs,
      isPlaying: isPlaying ?? this.isPlaying,
      queueIds: queueIds ?? this.queueIds,
      queueSnapshot: queueSnapshot ?? this.queueSnapshot,
      currentQueueIndex: currentQueueIndex ?? this.currentQueueIndex,
      repeatMode: repeatMode ?? this.repeatMode,
      shuffleEnabled: shuffleEnabled ?? this.shuffleEnabled,
      volume: volume ?? this.volume,
      scrollOffsets: scrollOffsets ?? this.scrollOffsets,
      libraryTabIndex: libraryTabIndex ?? this.libraryTabIndex,
      showVolumeBar: showVolumeBar ?? this.showVolumeBar,
      crossfadeEnabled: crossfadeEnabled ?? this.crossfadeEnabled,
      crossfadeDurationSeconds: crossfadeDurationSeconds ?? this.crossfadeDurationSeconds,
      infiniteRadioEnabled: infiniteRadioEnabled ?? this.infiniteRadioEnabled,
      cacheTtlMinutes: cacheTtlMinutes ?? this.cacheTtlMinutes,
      gaplessPlaybackEnabled: gaplessPlaybackEnabled ?? this.gaplessPlaybackEnabled,
      maxConcurrentDownloads: maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      wifiOnlyDownloads: wifiOnlyDownloads ?? this.wifiOnlyDownloads,
      storageLimitMB: storageLimitMB ?? this.storageLimitMB,
      autoCleanupEnabled: autoCleanupEnabled ?? this.autoCleanupEnabled,
      autoCleanupDays: autoCleanupDays ?? this.autoCleanupDays,
      streamingQuality: streamingQuality ?? this.streamingQuality,
      themePaletteId: themePaletteId ?? this.themePaletteId,
      customPrimaryColor: customPrimaryColor ?? this.customPrimaryColor,
      customSecondaryColor: customSecondaryColor ?? this.customSecondaryColor,
      customAccentColor: customAccentColor ?? this.customAccentColor,
      customThemeIsLight: customThemeIsLight ?? this.customThemeIsLight,
      visualizerEnabled: visualizerEnabled ?? this.visualizerEnabled,
      visualizerType: visualizerType ?? this.visualizerType,
      visualizerPosition: visualizerPosition ?? this.visualizerPosition,
      preCacheTrackCount: preCacheTrackCount ?? this.preCacheTrackCount,
      wifiOnlyCaching: wifiOnlyCaching ?? this.wifiOnlyCaching,
      isOfflineMode: isOfflineMode ?? this.isOfflineMode,
      submarineModeEnabled: submarineModeEnabled ?? this.submarineModeEnabled,
      batterySaverSnapshot: batterySaverSnapshot ?? this.batterySaverSnapshot,
      gridSize: gridSize ?? this.gridSize,
      useListMode: useListMode ?? this.useListMode,
      nowPlayingLayout: nowPlayingLayout ?? this.nowPlayingLayout,
      navTabOrder: navTabOrder ?? this.navTabOrder,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'currentTrackId': currentTrackId,
      'currentTrackName': currentTrackName,
      'currentAlbumId': currentAlbumId,
      'currentAlbumName': currentAlbumName,
      'positionMs': positionMs,
      'isPlaying': isPlaying,
      'queueIds': queueIds,
      'queueSnapshot': queueSnapshot,
      'currentQueueIndex': currentQueueIndex,
      'repeatMode': repeatMode,
      'shuffleEnabled': shuffleEnabled,
      'volume': volume,
      'scrollOffsets': scrollOffsets,
      'libraryTabIndex': libraryTabIndex,
      'showVolumeBar': showVolumeBar,
      'crossfadeEnabled': crossfadeEnabled,
      'crossfadeDurationSeconds': crossfadeDurationSeconds,
      'infiniteRadioEnabled': infiniteRadioEnabled,
      'cacheTtlMinutes': cacheTtlMinutes,
      'gaplessPlaybackEnabled': gaplessPlaybackEnabled,
      'maxConcurrentDownloads': maxConcurrentDownloads,
      'wifiOnlyDownloads': wifiOnlyDownloads,
      'storageLimitMB': storageLimitMB,
      'autoCleanupEnabled': autoCleanupEnabled,
      'autoCleanupDays': autoCleanupDays,
      'streamingQuality': streamingQuality.name,
      'themePaletteId': themePaletteId,
      'customPrimaryColor': customPrimaryColor,
      'customSecondaryColor': customSecondaryColor,
      'customAccentColor': customAccentColor,
      'customThemeIsLight': customThemeIsLight,
      'visualizerEnabled': visualizerEnabled,
      'visualizerType': visualizerType.name,
      'visualizerPosition': visualizerPosition.name,
      'preCacheTrackCount': preCacheTrackCount,
      'wifiOnlyCaching': wifiOnlyCaching,
      'isOfflineMode': isOfflineMode,
      'submarineModeEnabled': submarineModeEnabled,
      'batterySaverSnapshot': batterySaverSnapshot,
      'gridSize': gridSize,
      'useListMode': useListMode,
      'nowPlayingLayout': nowPlayingLayout.name,
      'navTabOrder': navTabOrder,
    };
  }

  factory PlaybackState.fromJson(Map<String, dynamic> json) {
    final rawOffsets = json['scrollOffsets'] as Map? ?? const {};
    return PlaybackState(
      currentTrackId: json['currentTrackId'] as String?,
      currentTrackName: json['currentTrackName'] as String?,
      currentAlbumId: json['currentAlbumId'] as String?,
      currentAlbumName: json['currentAlbumName'] as String?,
      positionMs: json['positionMs'] as int? ?? 0,
      isPlaying: json['isPlaying'] as bool? ?? false,
      queueIds: (json['queueIds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      queueSnapshot: (json['queueSnapshot'] as List<dynamic>?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          const [],
      currentQueueIndex: json['currentQueueIndex'] as int? ?? 0,
      repeatMode: json['repeatMode'] as String? ?? 'off',
      shuffleEnabled: json['shuffleEnabled'] as bool? ?? false,
      volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
      scrollOffsets: rawOffsets.entries.fold<Map<String, double>>({}, (map, entry) {
        if (entry.key is String && entry.value is num) {
          map[entry.key as String] = (entry.value as num).toDouble();
        }
        return map;
      }),
      libraryTabIndex: json['libraryTabIndex'] as int? ?? 0,
      showVolumeBar: json['showVolumeBar'] as bool? ?? true,
      crossfadeEnabled: json['crossfadeEnabled'] as bool? ?? false,
      crossfadeDurationSeconds: json['crossfadeDurationSeconds'] as int? ?? 3,
      infiniteRadioEnabled: json['infiniteRadioEnabled'] as bool? ?? false,
      cacheTtlMinutes: (json['cacheTtlMinutes'] as num?)?.toInt() ?? 2,
      gaplessPlaybackEnabled: json['gaplessPlaybackEnabled'] as bool? ?? true,
      maxConcurrentDownloads: (json['maxConcurrentDownloads'] as num?)?.toInt() ?? 3,
      wifiOnlyDownloads: json['wifiOnlyDownloads'] as bool? ?? false,
      storageLimitMB: (json['storageLimitMB'] as num?)?.toInt() ?? 0,
      autoCleanupEnabled: json['autoCleanupEnabled'] as bool? ?? false,
      autoCleanupDays: (json['autoCleanupDays'] as num?)?.toInt() ?? 30,
      streamingQuality: StreamingQualityExtension.fromString(json['streamingQuality'] as String?),
      themePaletteId: json['themePaletteId'] as String? ?? 'purple_ocean',
      customPrimaryColor: (json['customPrimaryColor'] as num?)?.toInt(),
      customSecondaryColor: (json['customSecondaryColor'] as num?)?.toInt(),
      customAccentColor: (json['customAccentColor'] as num?)?.toInt(),
      customThemeIsLight: json['customThemeIsLight'] as bool? ?? false,
      visualizerEnabled: json['visualizerEnabled'] as bool? ?? true,
      visualizerType: VisualizerTypeExtension.fromString(json['visualizerType'] as String?),
      visualizerPosition: VisualizerPositionExtension.fromString(json['visualizerPosition'] as String?),
      preCacheTrackCount: (json['preCacheTrackCount'] as num?)?.toInt() ?? 3,
      wifiOnlyCaching: json['wifiOnlyCaching'] as bool? ?? false,
      isOfflineMode: json['isOfflineMode'] as bool? ?? false,
      submarineModeEnabled: json['submarineModeEnabled'] as bool? ?? false,
      batterySaverSnapshot: (json['batterySaverSnapshot'] as Map?)?.cast<String, dynamic>(),
      gridSize: (json['gridSize'] as num?)?.toInt() ?? 2,
      useListMode: json['useListMode'] as bool? ?? false,
      nowPlayingLayout: NowPlayingLayoutExtension.fromString(json['nowPlayingLayout'] as String?),
      navTabOrder: (json['navTabOrder'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [0, 1, 2, 3, 4],
    );
  }

  /// Clears playback-related data while preserving UI settings.
  /// Returns a new PlaybackState with playback fields reset to defaults.
  PlaybackState clearPlayback() {
    // Cannot use copyWith because it uses ?? which won't set nullable fields to null
    return PlaybackState(
      currentTrackId: null,
      currentTrackName: null,
      currentAlbumId: null,
      currentAlbumName: null,
      positionMs: 0,
      isPlaying: false,
      queueIds: const [],
      queueSnapshot: const [],
      currentQueueIndex: 0,
      repeatMode: 'off',
      shuffleEnabled: false,
      volume: volume, // Preserve volume setting
      scrollOffsets: scrollOffsets, // Preserve UI settings
      libraryTabIndex: libraryTabIndex,
      showVolumeBar: showVolumeBar,
      crossfadeEnabled: crossfadeEnabled,
      crossfadeDurationSeconds: crossfadeDurationSeconds,
      infiniteRadioEnabled: infiniteRadioEnabled,
      cacheTtlMinutes: cacheTtlMinutes,
      gaplessPlaybackEnabled: gaplessPlaybackEnabled,
      maxConcurrentDownloads: maxConcurrentDownloads,
      wifiOnlyDownloads: wifiOnlyDownloads,
      storageLimitMB: storageLimitMB,
      autoCleanupEnabled: autoCleanupEnabled,
      autoCleanupDays: autoCleanupDays,
      streamingQuality: streamingQuality,
      themePaletteId: themePaletteId, // Preserve theme preference
      customPrimaryColor: customPrimaryColor, // Preserve custom theme colors
      customSecondaryColor: customSecondaryColor,
      customAccentColor: customAccentColor,
      customThemeIsLight: customThemeIsLight,
      visualizerEnabled: visualizerEnabled, // Preserve visualizer preference
      visualizerType: visualizerType, // Preserve visualizer type
      visualizerPosition: visualizerPosition, // Preserve visualizer position
      preCacheTrackCount: preCacheTrackCount, // Preserve smart cache settings
      wifiOnlyCaching: wifiOnlyCaching,
      submarineModeEnabled: submarineModeEnabled, // Preserve submarine mode
      batterySaverSnapshot: batterySaverSnapshot, // Preserve snapshot
      gridSize: gridSize, // Preserve grid size preference
      useListMode: useListMode, // Preserve list mode preference
      nowPlayingLayout: nowPlayingLayout, // Preserve Now Playing layout
      navTabOrder: navTabOrder, // Preserve nav tab order
    );
  }

  List<JellyfinTrack> toQueueTracks() {
    return queueSnapshot
        .map(JellyfinTrack.fromStorageJson)
        .toList(growable: false);
  }
}
