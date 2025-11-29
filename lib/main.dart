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
  );

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

class NautuneApp extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // New focused providers (Phase 1 refactoring)
        ChangeNotifierProvider.value(value: sessionProvider),
        ChangeNotifierProvider.value(value: connectivityProvider),
        ChangeNotifierProvider.value(value: uiStateProvider),
        ChangeNotifierProvider.value(value: libraryDataProvider),
        ChangeNotifierProvider.value(value: demoModeProvider),

        // Legacy app state (will be phased out)
        ChangeNotifierProvider.value(value: appState),
      ],
      child: MaterialApp(
        title: 'Nautune - Poseidon Music Player',
        theme: NautuneTheme.build(),
        debugShowCheckedModeBanner: false,
        routes: {
          '/queue': (context) => QueueScreen(appState: appState),
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
            return LibraryScreen(appState: appState);
          },
        ),
      ),
    );
  }
}
