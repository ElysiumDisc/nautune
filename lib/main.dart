import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'jellyfin/jellyfin_service.dart';
import 'jellyfin/jellyfin_session_store.dart';
import 'providers/connectivity_provider.dart';
import 'providers/demo_mode_provider.dart';
import 'providers/library_data_provider.dart';
import 'providers/session_provider.dart';
import 'providers/ui_state_provider.dart';
import 'screens/library_screen.dart';
import 'screens/login_screen.dart';
import 'screens/queue_screen.dart';
import 'services/bootstrap_service.dart';
import 'services/connectivity_service.dart';
import 'services/download_service.dart';
import 'services/local_cache_service.dart';
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
  final downloadService = DownloadService(jellyfinService: jellyfinService);

  final demoModeProvider = DemoModeProvider(
    sessionProvider: sessionProvider,
    downloadService: downloadService,
  );

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

  runApp(
    NautuneApp(
      appState: appState,
      sessionProvider: sessionProvider,
      connectivityProvider: connectivityProvider,
      uiStateProvider: uiStateProvider,
      libraryDataProvider: libraryDataProvider,
      demoModeProvider: demoModeProvider,
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
  });

  final NautuneAppState appState;
  final SessionProvider sessionProvider;
  final ConnectivityProvider connectivityProvider;
  final UIStateProvider uiStateProvider;
  final LibraryDataProvider libraryDataProvider;
  final DemoModeProvider demoModeProvider;

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
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        // App going to background - ensure playback state is saved
        debugPrint('📱 App lifecycle: $state - saving playback state');
        _savePlaybackState();
        break;
        
      case AppLifecycleState.resumed:
        // App returning to foreground - check connectivity and refresh if needed
        debugPrint('📱 App lifecycle: resumed - checking connectivity');
        _onAppResumed();
        break;
        
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // App being detached - final save
        debugPrint('📱 App lifecycle: $state');
        _savePlaybackState();
        break;
    }
  }

  void _savePlaybackState() {
    // Save full playback state when going to background or being force closed
    final audioService = widget.appState.audioPlayerService;
    final currentTrack = audioService.currentTrack;
    
    if (currentTrack != null) {
      debugPrint('💾 Saving playback state for: ${currentTrack.name}');
      // Trigger a full state save including queue, position, and all settings
      audioService.saveFullPlaybackState();
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

        // Legacy app state (will be phased out)
        ChangeNotifierProvider.value(value: widget.appState),
      ],
      child: MaterialApp(
        title: 'Nautune - Poseidon Music Player',
        theme: NautuneTheme.build(),
        debugShowCheckedModeBanner: false,
        routes: {
          '/queue': (context) => const QueueScreen(),
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
