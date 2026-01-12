import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';
import 'jellyfin/jellyfin_service.dart';
import 'jellyfin/jellyfin_session_store.dart';
import 'providers/connectivity_provider.dart';
import 'providers/demo_mode_provider.dart';
import 'providers/library_data_provider.dart';
import 'providers/session_provider.dart';
import 'providers/sync_status_provider.dart';
import 'providers/ui_state_provider.dart';
import 'screens/library_screen.dart';
import 'screens/login_screen.dart';
import 'screens/mini_player_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/settings_screen.dart';
import 'services/bootstrap_service.dart';
import 'services/connectivity_service.dart';
import 'services/download_service.dart';
import 'services/local_cache_service.dart';
import 'services/notification_service.dart';
import 'services/playback_state_store.dart';
import 'theme/nautune_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize core services
  final jellyfinService = JellyfinService();
  final cacheService = await LocalCacheService.create();
  final connectivityService = ConnectivityService();
  final bootstrapService = BootstrapService(
    cacheService: cacheService,
    jellyfinService: jellyfinService,
  );
  final playbackStateStore = PlaybackStateStore();
  final sessionStore = JellyfinSessionStore();
  final notificationService = NotificationService();
  await notificationService.initialize();

  // Initialize providers first
  final sessionProvider = SessionProvider(
    jellyfinService: jellyfinService,
    sessionStore: sessionStore,
  );

  final connectivityProvider = ConnectivityProvider(
    connectivityService: connectivityService,
  );

  final uiStateProvider = UIStateProvider(
    playbackStateStore: playbackStateStore,
  );

  final libraryDataProvider = LibraryDataProvider(
    sessionProvider: sessionProvider,
    jellyfinService: jellyfinService,
    cacheService: cacheService,
  );

  // Create download service standalone (needed by both appState and demoModeProvider)
  final downloadService = DownloadService(
    jellyfinService: jellyfinService,
    notificationService: notificationService,
  );

  final demoModeProvider = DemoModeProvider(
    sessionProvider: sessionProvider,
    downloadService: downloadService,
  );

  final syncStatusProvider = SyncStatusProvider();

  // Initialize legacy app state with demo mode provider
  final appState = NautuneAppState(
    jellyfinService: jellyfinService,
    sessionStore: sessionStore,
    playbackStateStore: playbackStateStore,
    cacheService: cacheService,
    bootstrapService: bootstrapService,
    connectivityService: connectivityService,
    downloadService: downloadService,
    demoModeProvider: demoModeProvider,
    sessionProvider: sessionProvider,);

  // Initialize providers in sequence
  await sessionProvider.initialize();
  await connectivityProvider.initialize();
  await uiStateProvider.initialize();

  // Initialize legacy app state
  unawaited(appState.initialize());

  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    await windowManager.ensureInitialized();
  }

  runApp(
    NautuneApp(
      appState: appState,
      sessionProvider: sessionProvider,
      connectivityProvider: connectivityProvider,
      uiStateProvider: uiStateProvider,
      libraryDataProvider: libraryDataProvider,
      demoModeProvider: demoModeProvider,
      syncStatusProvider: syncStatusProvider,
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
  });

  final NautuneAppState appState;
  final SessionProvider sessionProvider;
  final ConnectivityProvider connectivityProvider;
  final UIStateProvider uiStateProvider;
  final LibraryDataProvider libraryDataProvider;
  final DemoModeProvider demoModeProvider;
  final SyncStatusProvider syncStatusProvider;

  @override
  State<NautuneApp> createState() => _NautuneAppState();
}

class _NautuneAppState extends State<NautuneApp> with WidgetsBindingObserver, WindowListener {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<String>? _traySubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      windowManager.addListener(this);
      _initWindow();
    }
    
    // Listen to tray actions
    final trayService = widget.appState.trayService;
    if (trayService != null) {
      _traySubscription = trayService.actionStream.listen((action) async {
        if (action == 'settings') {
          _navigatorKey.currentState?.push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          );
        } else if (action == 'show') {
          final isVisible = await windowManager.isVisible();
          final isMinimized = await windowManager.isMinimized();
          
          if (isVisible && !isMinimized) {
            await windowManager.hide();
          } else {
            await _restoreWindow();
          }
        } else if (action == 'quit') {
          await _forceClose();
        }
      });
    }
  }

  Future<void> _initWindow() async {
    await windowManager.setPreventClose(true);
  }

  Future<void> _restoreWindow() async {
    final isVisible = await windowManager.isVisible();
    if (!isVisible) {
      await windowManager.show();
    }
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.focus();
  }

  Future<void> _forceClose() async {
    await windowManager.destroy();
  }

  @override
  void onWindowClose() async {
    final isPreventClose = await windowManager.isPreventClose();
    if (isPreventClose) {
      await windowManager.hide();
    }
  }

  @override
  void dispose() {
    _traySubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        // App going to background - ensure playback state is saved
        // Use unawaited but the save is synchronous enough for iOS
        debugPrint('📱 App lifecycle: $state - saving playback state');
        unawaited(_savePlaybackState());
        break;
        
      case AppLifecycleState.resumed:
        // App returning to foreground - check connectivity and refresh if needed
        debugPrint('📱 App lifecycle: resumed - checking connectivity');
        unawaited(_onAppResumed());
        break;
        
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // App being detached - final save
        debugPrint('📱 App lifecycle: $state');
        unawaited(_savePlaybackState());
        break;
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

  Future<void> _onAppResumed() async {
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

        // Legacy app state (will be phased out)
        ChangeNotifierProvider.value(value: widget.appState),
      ],
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'Nautune - Poseidon Music Player',
        theme: NautuneTheme.build(),
        debugShowCheckedModeBanner: false,
        routes: {
          '/queue': (context) => const QueueScreen(),
          '/mini': (context) => const MiniPlayerScreen(),
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
      ),
    );
  }
}
