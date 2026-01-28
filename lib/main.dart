import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';
import 'tui/tui_app.dart';
import 'jellyfin/jellyfin_service.dart';
import 'jellyfin/jellyfin_session_store.dart';
import 'providers/connectivity_provider.dart';
import 'providers/demo_mode_provider.dart';
import 'providers/library_data_provider.dart';
import 'providers/session_provider.dart';
import 'providers/sync_status_provider.dart';
import 'providers/syncplay_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/ui_state_provider.dart';
import 'screens/library_screen.dart';
import 'screens/login_screen.dart';
import 'screens/mini_player_screen.dart';
import 'screens/collab_playlist_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/relax_mode_screen.dart';
import 'screens/network_screen.dart';
import 'screens/settings_screen.dart';
import 'services/bootstrap_service.dart';
import 'services/connectivity_service.dart';
import 'services/download_service.dart';
import 'services/listening_analytics_service.dart';
import 'services/local_cache_service.dart';
import 'services/deep_link_service.dart';
import 'services/notification_service.dart';
import 'services/playback_state_store.dart';

/// Migrates old Hive files from ~/Documents/ to ~/Documents/nautune/
/// Only runs if files exist in old location and NOT in new location.
Future<void> _migrateHiveFiles() async {
  final docsDir = await getApplicationDocumentsDirectory();
  final oldPath = docsDir.path;
  final newPath = '${docsDir.path}${Platform.pathSeparator}nautune';
  final newDir = Directory(newPath);

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

  // Check if any files already exist in the new location
  if (await newDir.exists()) {
    for (final boxName in hiveBoxNames) {
      final newHiveFile = File('$newPath${Platform.pathSeparator}$boxName.hive');
      if (await newHiveFile.exists()) {
        // Files already in new location, no migration needed
        return;
      }
    }
  }

  // Check if old files exist and need migration
  final filesToMove = <File>[];
  for (final boxName in hiveBoxNames) {
    final oldHiveFile = File('$oldPath${Platform.pathSeparator}$boxName.hive');
    final oldLockFile = File('$oldPath${Platform.pathSeparator}$boxName.lock');
    if (await oldHiveFile.exists()) {
      filesToMove.add(oldHiveFile);
    }
    if (await oldLockFile.exists()) {
      filesToMove.add(oldLockFile);
    }
  }

  // No old files to migrate
  if (filesToMove.isEmpty) {
    return;
  }

  // Create new directory and move files
  if (!await newDir.exists()) {
    await newDir.create(recursive: true);
  }

  for (final file in filesToMove) {
    final fileName = file.path.split(Platform.pathSeparator).last;
    final newFile = File('$newPath${Platform.pathSeparator}$fileName');
    try {
      await file.rename(newFile.path);
    } catch (_) {
      // If rename fails (cross-device), copy and delete
      await file.copy(newFile.path);
      await file.delete();
    }
  }
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Detect TUI mode from command line, environment, or dart-define
  const tuiModeDefine = bool.fromEnvironment('TUI_MODE', defaultValue: false);
  final isTuiMode = tuiModeDefine ||
      Platform.environment['NAUTUNE_TUI_MODE'] == '1' ||
      args.contains('--tui');

  // Migrate old Hive files to nautune subfolder (one-time migration)
  await _migrateHiveFiles();

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

  final themeProvider = ThemeProvider(
    playbackStateStore: playbackStateStore,
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

  // Initialize SyncPlay provider for collaborative playlists
  // Created after appState so we can access audioPlayerService
  final syncPlayProvider = SyncPlayProvider(
    sessionProvider: sessionProvider,
    jellyfinService: jellyfinService,
    audioPlayerService: appState.audioPlayerService,
  );

  // Initialize providers and services in sequence
  await sessionProvider.initialize();
  await connectivityProvider.initialize();
  await uiStateProvider.initialize();
  await themeProvider.initialize();
  await ListeningAnalyticsService().initialize();

  // Initialize legacy app state
  unawaited(appState.initialize());

  // Initialize deep link service for SyncPlay join links
  await DeepLinkService.instance.initialize();

  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    await windowManager.ensureInitialized();

    // Configure window for TUI mode (Linux only)
    if (isTuiMode && Platform.isLinux) {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setBackgroundColor(Colors.black);
      await windowManager.setSize(const Size(1000, 600));
      await windowManager.setMinimumSize(const Size(800, 400));
    }
  }

  // Launch TUI or GUI mode
  if (isTuiMode && Platform.isLinux) {
    runApp(
      TuiNautuneApp(
        appState: appState,
        sessionProvider: sessionProvider,
        connectivityProvider: connectivityProvider,
        uiStateProvider: uiStateProvider,
        libraryDataProvider: libraryDataProvider,
        demoModeProvider: demoModeProvider,
        syncStatusProvider: syncStatusProvider,
        syncPlayProvider: syncPlayProvider,
        themeProvider: themeProvider,
      ),
    );
  } else {
    runApp(
      NautuneApp(
        appState: appState,
        sessionProvider: sessionProvider,
        connectivityProvider: connectivityProvider,
        uiStateProvider: uiStateProvider,
        libraryDataProvider: libraryDataProvider,
        demoModeProvider: demoModeProvider,
        syncStatusProvider: syncStatusProvider,
        syncPlayProvider: syncPlayProvider,
        themeProvider: themeProvider,
      ),
    );
  }
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
    required this.syncPlayProvider,
    required this.themeProvider,
  });

  final NautuneAppState appState;
  final SessionProvider sessionProvider;
  final ConnectivityProvider connectivityProvider;
  final UIStateProvider uiStateProvider;
  final LibraryDataProvider libraryDataProvider;
  final DemoModeProvider demoModeProvider;
  final SyncStatusProvider syncStatusProvider;
  final SyncPlayProvider syncPlayProvider;
  final ThemeProvider themeProvider;

  @override
  State<NautuneApp> createState() => _NautuneAppState();
}

class _NautuneAppState extends State<NautuneApp> with WidgetsBindingObserver, WindowListener {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<String>? _traySubscription;
  StreamSubscription<String>? _deepLinkSubscription;
  String? _deferredSyncPlayGroupId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      windowManager.addListener(this);
      _initWindow();
    }

    // Listen to deep link SyncPlay join events
    _deepLinkSubscription = DeepLinkService.instance.syncPlayJoinStream.listen((groupId) {
      _handleSyncPlayJoin(groupId);
    });

    // Check for pending cold start join
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pendingGroupId = DeepLinkService.instance.pendingJoinGroupId;
      debugPrint('🔗 Post-frame callback: pendingGroupId=$pendingGroupId, session=${widget.sessionProvider.session != null}');
      if (pendingGroupId != null) {
        // Add delay to ensure navigator context is ready after cold start
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) {
            _handleSyncPlayJoin(pendingGroupId);
          }
        });
      }
    });

    // Add listener for session changes to handle deferred deep links
    widget.sessionProvider.addListener(_onSessionChanged);

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

  void _onSessionChanged() {
    debugPrint('🔗 _onSessionChanged: deferred=$_deferredSyncPlayGroupId, session=${widget.sessionProvider.session != null}');
    // Process deferred SyncPlay join when session becomes available
    if (_deferredSyncPlayGroupId != null && widget.sessionProvider.session != null) {
      final groupId = _deferredSyncPlayGroupId!;
      _deferredSyncPlayGroupId = null;
      debugPrint('🔗 Processing deferred join for group: $groupId');

      // Small delay to ensure UI is ready
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          _handleSyncPlayJoin(groupId);
        }
      });
    }
  }

  void _handleSyncPlayJoin(String groupId, {int retryCount = 0}) {
    debugPrint('🔗 _handleSyncPlayJoin: groupId=$groupId, session=${widget.sessionProvider.session != null}, retry=$retryCount');
    if (widget.sessionProvider.session == null) {
      debugPrint('🔗 SyncPlay join deferred: Waiting for session');
      _deferredSyncPlayGroupId = groupId;
      return;
    }

    // Clear any deferred join since we're handling it now
    _deferredSyncPlayGroupId = null;

    // Show join dialog
    final context = _navigatorKey.currentContext;
    debugPrint('🔗 Showing join dialog: context=${context != null}');
    if (context != null) {
      showDialog(
        context: context,
        builder: (context) => JoinCollabDialog(groupId: groupId),
      );
    } else if (retryCount < 3) {
      // Context not ready yet, retry after delay
      debugPrint('🔗 Context null, retrying in 500ms...');
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
          _handleSyncPlayJoin(groupId, retryCount: retryCount + 1);
        }
      });
    } else {
      debugPrint('🔗 Failed to show join dialog after $retryCount retries');
    }
  }

  @override
  void dispose() {
    _traySubscription?.cancel();
    _deepLinkSubscription?.cancel();
    widget.sessionProvider.removeListener(_onSessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      windowManager.removeListener(this);
    }

    // Dispose services to prevent memory leaks
    widget.appState.audioPlayerService.dispose();
    widget.appState.dispose();

    // Dispose providers that may have resources
    widget.connectivityProvider.dispose();
    widget.syncPlayProvider.dispose();

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
        // Also ensure analytics data is persisted
        unawaited(ListeningAnalyticsService().saveAnalytics());
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
        ChangeNotifierProvider.value(value: widget.syncPlayProvider),
        ChangeNotifierProvider.value(value: widget.themeProvider),

        // Legacy app state (will be phased out)
        ChangeNotifierProvider.value(value: widget.appState),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) => MaterialApp(
          navigatorKey: _navigatorKey,
          title: 'Nautune - Poseidon Music Player',
          theme: themeProvider.themeData,
          debugShowCheckedModeBanner: false,
          routes: {
            '/queue': (context) => const QueueScreen(),
            '/mini': (context) => const MiniPlayerScreen(),
            '/collab': (context) => const CollabPlaylistScreen(),
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
        ),
      ),
    );
  }
}
