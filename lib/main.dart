import 'package:flutter/material.dart';

import 'app_state.dart';
import 'jellyfin/jellyfin_service.dart';
import 'jellyfin/jellyfin_session_store.dart';
import 'screens/library_screen.dart';
import 'screens/login_screen.dart';
import 'screens/queue_screen.dart';
import 'services/playback_state_store.dart';
import 'theme/nautune_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final appState = NautuneAppState(
    jellyfinService: JellyfinService(),
    sessionStore: JellyfinSessionStore(),
    playbackStateStore: PlaybackStateStore(),
  );
  await appState.initialize();
  runApp(NautuneApp(appState: appState));
}

class NautuneApp extends StatelessWidget {
  const NautuneApp({super.key, required this.appState});

  final NautuneAppState appState;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nautune - Poseidon Music Player',
      theme: NautuneTheme.build(),
      debugShowCheckedModeBanner: false,
      routes: {
        '/queue': (context) => QueueScreen(appState: appState),
      },
      home: AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          if (!appState.isInitialized) {
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(),
              ),
            );
          }

          if (appState.session == null) {
            return LoginScreen(appState: appState);
          }

          return LibraryScreen(appState: appState);
        },
      ),
    );
  }
}
