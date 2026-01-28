import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../providers/connectivity_provider.dart';
import '../providers/demo_mode_provider.dart';
import '../providers/library_data_provider.dart';
import '../providers/session_provider.dart';
import '../providers/sync_status_provider.dart';
import '../providers/syncplay_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/ui_state_provider.dart';
import 'layout/tui_shell.dart';
import 'tui_theme.dart';

/// The TUI mode entry point for Nautune.
/// Provides a terminal-like interface with vim-style navigation.
class TuiNautuneApp extends StatelessWidget {
  const TuiNautuneApp({
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
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: sessionProvider),
        ChangeNotifierProvider.value(value: connectivityProvider),
        ChangeNotifierProvider.value(value: uiStateProvider),
        ChangeNotifierProvider.value(value: libraryDataProvider),
        ChangeNotifierProvider.value(value: demoModeProvider),
        ChangeNotifierProvider.value(value: syncStatusProvider),
        ChangeNotifierProvider.value(value: syncPlayProvider),
        ChangeNotifierProvider.value(value: themeProvider),
        ChangeNotifierProvider.value(value: appState),
      ],
      child: MaterialApp(
        title: 'Nautune TUI',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: TuiColors.background,
          colorScheme: const ColorScheme.dark(
            primary: TuiColors.accent,
            surface: TuiColors.background,
          ),
        ),
        home: Consumer2<SessionProvider, NautuneAppState>(
          builder: (context, session, app, _) {
            // Show loading while initializing
            if (!session.isInitialized || !app.isInitialized) {
              return Scaffold(
                backgroundColor: TuiColors.background,
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Nautune TUI',
                        style: TuiTextStyles.title,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Loading...',
                        style: TuiTextStyles.dim,
                      ),
                    ],
                  ),
                ),
              );
            }

            // Show login prompt if no session
            if (session.session == null) {
              return Scaffold(
                backgroundColor: TuiColors.background,
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Nautune TUI',
                        style: TuiTextStyles.title,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Not logged in.',
                        style: TuiTextStyles.normal,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Please run Nautune in GUI mode first to log in.',
                        style: TuiTextStyles.dim,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Press q to quit',
                        style: TuiTextStyles.accent,
                      ),
                    ],
                  ),
                ),
              );
            }

            // Show TUI shell
            return const TuiShell();
          },
        ),
      ),
    );
  }
}
