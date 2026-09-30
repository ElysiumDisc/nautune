import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'jellyfin/jellyfin_service.dart';
import 'jellyfin/jellyfin_session_store.dart';
import 'models/playback_state.dart';
import 'models/appearance.dart';
import 'providers/connectivity_provider.dart';
import 'providers/demo_mode_provider.dart';
import 'providers/library_data_provider.dart';
import 'providers/now_playing_colors_provider.dart';
import 'providers/session_provider.dart';
import 'providers/sync_status_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/ui_state_provider.dart';
import 'screens/library_screen.dart';
import 'screens/login_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/relax_mode_screen.dart';
import 'screens/network_screen.dart';
import 'services/bootstrap_service.dart';
import 'services/connectivity_service.dart';
import 'services/download_service.dart';
import 'services/equalizer_service.dart';
import 'services/lastfm_service.dart';
import 'services/listenbrainz_service.dart';
import 'services/listening_analytics_service.dart';
import 'services/local_cache_service.dart';
import 'services/notification_service.dart';
import 'services/ios_fft_service.dart';
import 'services/playback_state_store.dart';
import 'app_version.dart';

/// Migrates old Hive files from ~/Documents/ to ~/Documents/nautune/
/// Only runs if files exist in old location and NOT in new location.
Future<void> _migrateHiveFiles() async {
  final docsDir = await getApplicationDocumentsDirectory();
  final newPath = '${docsDir.path}${Platform.pathSeparator}nautune';
  final markerFile = File('$newPath${Platform.pathSeparator}.migration_done');

  // Skip migration if marker file exists
  if (await markerFile.exists()) {
    return;
  }

  final oldPath = docsDir.path;
  const hiveBoxNames = [
    'nautune_session',
    'nautune_playback',
    'nautune_downloads',
    'nautune_cache',
    'nautune_playlists',
    'nautune_sync_queue',
    'nautune_search_history',
    'nautune_analytics',
  ];

  // Check if any files already exist in the new location to avoid re-migration
  final newDir = Directory(newPath);
  if (await newDir.exists()) {
    final newFilesCheck = await Future.wait(hiveBoxNames.map((boxName) {
      return File('$newPath${Platform.pathSeparator}$boxName.hive').exists();
    }));
    if (newFilesCheck.any((exists) => exists)) {
      // Create marker file and skip
      await markerFile.create(recursive: true);
      return;
    }
  }

  // Check if old files exist and need migration
  final oldFilesExist = await Future.wait(hiveBoxNames.expand((boxName) => [
        File('$oldPath${Platform.pathSeparator}$boxName.hive').exists(),
        File('$oldPath${Platform.pathSeparator}$boxName.lock').exists(),
      ]));

  final filesToMove = <File>[];
  var index = 0;
  for (final boxName in hiveBoxNames) {
    if (oldFilesExist[index++]) {
      filesToMove.add(File('$oldPath${Platform.pathSeparator}$boxName.hive'));
    }
    if (oldFilesExist[index++]) {
      filesToMove.add(File('$oldPath${Platform.pathSeparator}$boxName.lock'));
    }
  }

  // No old files to migrate
  if (filesToMove.isEmpty) {
    // Still create marker file if new directory exists (fresh install)
    if (await newDir.exists()) {
      await markerFile.create(recursive: true);
    }
    return;
  }

  // Create new directory and move files
  if (!await newDir.exists()) {
    await newDir.create(recursive: true);
  }

  await Future.wait(filesToMove.map((file) async {
    final fileName = file.path.split(Platform.pathSeparator).last;
    final newFile = File('$newPath${Platform.pathSeparator}$fileName');
    try {
      await file.rename(newFile.path);
    } catch (_) {
      // If rename fails (cross-device), copy and delete
      await file.copy(newFile.path);
      await file.delete();
    }
  }));

  // Mark migration as complete
  await markerFile.create();
}

/// Awaits [future], logging instead of propagating a failure so one broken
/// service can't stop the app from launching.
Future<void> _guard(Future<Object?> future, String label) async {
  try {
    await future;
  } catch (error, stackTrace) {
    debugPrint('⚠️ $label initialization failed: $error');
    FlutterError.reportError(FlutterErrorDetails(
      exception: error,
      stack: stackTrace,
      library: 'main',
      context: ErrorDescription('initializing $label'),
    ));
  }
}

Future<void> main() async {
  final stopwatch = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();

  // Set global image cache limits to prevent OOM on large libraries.
  // Tuned for music-app workload (1000-5000 album grid scrolling) — at 500/50MB
  // we saw eviction thrashing on libraries >2000 albums; 1500/100MB stays safe
  // on phones and removes the thrashing on iPad.
  PaintingBinding.instance.imageCache.maximumSize = 1500;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 100 * 1024 * 1024; // 100MB

  // The Hive file migration must finish before any box is opened: opening
  // a box first creates a file in the new location, which makes the
  // migration think it already ran (and skip the user's old data).
  await _guard(_migrateHiveFiles(), 'Hive file migration');

  // Parallelize non-dependent initializations
  final results = await Future.wait([
    AppVersion.init(),
    LocalCacheService.create(),
  ]);

  final cacheService = results[1] as LocalCacheService;

  // Initialize core services
  final jellyfinService = JellyfinService();
  final connectivityService = ConnectivityService();
  final bootstrapService = BootstrapService(
    cacheService: cacheService,
    jellyfinService: jellyfinService,
  );
  final playbackStateStore = PlaybackStateStore();
  final sessionStore = JellyfinSessionStore();
  final notificationService = NotificationService();
  await _guard(notificationService.initialize(), 'Notifications');

  // Initialize providers
  final sessionProvider = SessionProvider(
    jellyfinService: jellyfinService,
    sessionStore: sessionStore,
  );

  final connectivityProvider = ConnectivityProvider(
    connectivityService: connectivityService,
  );

  final uiStateProvider = UIStateProvider(
    playbackStateStore: playbackStateStore,
    jellyfinService: jellyfinService,
  );

  final libraryDataProvider = LibraryDataProvider(
    sessionProvider: sessionProvider,
    jellyfinService: jellyfinService,
    cacheService: cacheService,
  );

  final downloadService = DownloadService(
    jellyfinService: jellyfinService,
    notificationService: notificationService,
  );

  final demoModeProvider = DemoModeProvider(
    sessionProvider: sessionProvider,
    downloadService: downloadService,
  );

  final syncStatusProvider = SyncStatusProvider();

  final themeProvider = ThemeProvider(
    playbackStateStore: playbackStateStore,
  );

  final appState = NautuneAppState(
    jellyfinService: jellyfinService,
    sessionStore: sessionStore,
    playbackStateStore: playbackStateStore,
    cacheService: cacheService,
    bootstrapService: bootstrapService,
    connectivityService: connectivityService,
    downloadService: downloadService,
    demoModeProvider: demoModeProvider,
    sessionProvider: sessionProvider,
    libraryDataProvider: libraryDataProvider,
    syncStatusProvider: syncStatusProvider,
  );

  final nowPlayingColorsProvider = NowPlayingColorsProvider(
    audioService: appState.audioPlayerService,
    jellyfinService: jellyfinService,
    downloadService: downloadService,
  );

  // Read the persisted playback/UI state once and share it.
  PlaybackState? storedPlaybackState;
  try {
    storedPlaybackState = await playbackStateStore.load();
  } catch (error) {
    debugPrint('⚠️ Failed to load playback state: $error');
  }

  // Before the session is restored: loads that start on the session change
  // must already see the user's offline choice.
  appState.primeStoredPreferences(storedPlaybackState);

  // Connectivity only asks the OS for a network transport (fast), but it
  // must never hold up the first frame.
  unawaited(_guard(connectivityProvider.initialize(), 'Connectivity'));

  // Initialize providers/services in parallel. A failing service must not
  // keep the app from starting, so each one is guarded.
  await Future.wait<void>([
    _guard(sessionProvider.initialize(), 'Session'),
    _guard(uiStateProvider.initialize(storedState: storedPlaybackState), 'UI state'),
    _guard(themeProvider.initialize(storedState: storedPlaybackState), 'Theme'),
    _guard(ListeningAnalyticsService().initialize(), 'Listening analytics'),
    _guard(LastFmService.instance.initialize(), 'Last.fm'),
    _guard(ListenBrainzService().initialize(), 'ListenBrainz'),
    _guard(EqualizerService.instance.initialize(playbackStateStore), 'Equalizer'),
  ]);

  // Initialize legacy app state
  unawaited(appState.initialize(storedPlaybackState: storedPlaybackState));

  debugPrint('🚀 App initialization took: ${stopwatch.elapsedMilliseconds}ms');

  runApp(
    NautuneApp(
      appState: appState,
      sessionProvider: sessionProvider,
      connectivityProvider: connectivityProvider,
      uiStateProvider: uiStateProvider,
      libraryDataProvider: libraryDataProvider,
      demoModeProvider: demoModeProvider,
      syncStatusProvider: syncStatusProvider,
      themeProvider: themeProvider,
      nowPlayingColorsProvider: nowPlayingColorsProvider,
    ),
  );
}

class NautuneApp extends StatefulWidget {
  const NautuneApp({
    super.key,
    required this.appState,
    required this.sessionProvider,
    required this.connectivityProvider,
    required this.uiStateProvider,
    required this.libraryDataProvider,
    required this.demoModeProvider,
    required this.syncStatusProvider,
    required this.themeProvider,
    required this.nowPlayingColorsProvider,
  });

  final NautuneAppState appState;
  final SessionProvider sessionProvider;
  final ConnectivityProvider connectivityProvider;
  final UIStateProvider uiStateProvider;
  final LibraryDataProvider libraryDataProvider;
  final DemoModeProvider demoModeProvider;
  final SyncStatusProvider syncStatusProvider;
  final ThemeProvider themeProvider;
  final NowPlayingColorsProvider nowPlayingColorsProvider;

  @override
  State<NautuneApp> createState() => _NautuneAppState();
}

class _NautuneAppState extends State<NautuneApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    // Dispose services to prevent memory leaks
    widget.appState.audioPlayerService.dispose();
    widget.appState.dispose();

    // Dispose providers that may have resources
    widget.connectivityProvider.dispose();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.inactive:
        // Transient (Control Center, notification shade, call banner, app
        // switcher): the app is still visible and audio keeps playing, so
        // don't suspend reporting/FFT or reconfigure the audio session here.
        // Persist state cheaply though - the app can be killed straight from
        // the app switcher without ever reaching `paused`.
        debugPrint('📱 App lifecycle: $state - saving playback state');
        unawaited(_savePlaybackState());
        unawaited(ListeningAnalyticsService().saveAnalytics());
        break;

      case AppLifecycleState.paused:
        // App going to background - ensure playback state is saved
        // Use unawaited but the save is synchronous enough for iOS
        debugPrint('📱 App lifecycle: $state - saving playback state');
        unawaited(_savePlaybackState());
        // Also ensure analytics data is persisted
        unawaited(ListeningAnalyticsService().saveAnalytics());
        // Broadcast media session state so lock screen controls stay active
        unawaited(_broadcastMediaSessionState());
        _suspendBackgroundWork();
        break;

      case AppLifecycleState.resumed:
        // App returning to foreground - check connectivity and refresh if needed
        debugPrint('📱 App lifecycle: resumed - checking connectivity');
        _resumeBackgroundWork();
        unawaited(_onAppResumed());
        break;

      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // App being detached - final save
        debugPrint('📱 App lifecycle: $state');
        unawaited(_savePlaybackState());
        _suspendBackgroundWork();
        break;
    }
  }

  /// Stop polling/timers/native taps that don't need to run while backgrounded.
  /// Cheap and idempotent — safe to call from any lifecycle transition.
  void _suspendBackgroundWork() {
    widget.appState.audioPlayerService.reportingService?.suspendForBackground();
    if (Platform.isIOS) {
      unawaited(IOSFFTService.instance.suspendForBackground());
    }
  }

  void _resumeBackgroundWork() {
    widget.appState.audioPlayerService.reportingService?.resumeFromBackground();
    if (Platform.isIOS) {
      unawaited(IOSFFTService.instance.resumeFromBackground());
    }
  }

  Future<void> _savePlaybackState() async {
    // Save full playback state when going to background or being force closed
    // IMPORTANT: This must complete before iOS terminates the app
    final audioService = widget.appState.audioPlayerService;
    final currentTrack = audioService.currentTrack;
    
    if (currentTrack != null) {
      debugPrint('💾 Saving playback state for: ${currentTrack.name}');
      // Await the save to ensure it completes before app termination
      await audioService.saveFullPlaybackState();
    }
  }

  Future<void> _broadcastMediaSessionState() async {
    try {
      await widget.appState.audioPlayerService.reactivateAudioSession();
    } catch (e) {
      debugPrint('⚠️ Failed to broadcast media session state: $e');
    }
  }

  Future<void> _onAppResumed() async {
    // Reactivate audio session on iOS when returning from background
    // This fixes lock screen playback getting stuck with greyed-out controls
    await widget.appState.audioPlayerService.reactivateAudioSession();

    // Check connectivity when app returns to foreground
    await widget.connectivityProvider.checkConnectivity();

    // If we're back online and have a session, trigger a light refresh
    if (widget.connectivityProvider.networkAvailable &&
        widget.sessionProvider.session != null &&
        !widget.demoModeProvider.isDemoMode) {
      // Don't force refresh everything, just update critical data
      debugPrint('📶 App resumed online - background sync will handle updates');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // New focused providers (Phase 1 refactoring)
        ChangeNotifierProvider.value(value: widget.sessionProvider),
        ChangeNotifierProvider.value(value: widget.connectivityProvider),
        ChangeNotifierProvider.value(value: widget.uiStateProvider),
        ChangeNotifierProvider.value(value: widget.libraryDataProvider),
        ChangeNotifierProvider.value(value: widget.demoModeProvider),
        ChangeNotifierProvider.value(value: widget.syncStatusProvider),
        ChangeNotifierProvider.value(value: widget.themeProvider),
        ChangeNotifierProvider.value(value: widget.nowPlayingColorsProvider),

        // Legacy app state (will be phased out)
        ChangeNotifierProvider.value(value: widget.appState),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          // Only rebuild the app theme on artwork changes when the user
          // chose the Now Playing accent.
          final accent = themeProvider.accentSource == AccentSource.nowPlaying
              ? context.select<NowPlayingColorsProvider, Color?>((c) => c.accent)
              : null;
          return MaterialApp(
          title: 'Nautune - Poseidon Music Player',
          theme: themeProvider.themeFor(Brightness.light, accent: accent),
          darkTheme: themeProvider.themeFor(Brightness.dark, accent: accent),
          themeMode: themeProvider.themeMode,
          debugShowCheckedModeBanner: false,
          routes: {
            '/queue': (context) => const QueueScreen(),
            '/relax': (context) => const RelaxModeScreen(),
            '/network': (context) => const NetworkScreen(),
          },
          home: Consumer2<SessionProvider, NautuneAppState>(
          builder: (context, session, app, _) {
            // Show loading while initializing
            if (!session.isInitialized || !app.isInitialized) {
              return const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(),
                ),
              );
            }

            // Show login if no session
            if (session.session == null) {
              return const LoginScreen();
            }

            // Show library screen
            return const LibraryScreen();
          },
        ),
        );
        },
      ),
    );
  }
}
