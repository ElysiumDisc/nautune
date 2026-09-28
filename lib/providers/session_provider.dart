import 'dart:async';

import 'package:flutter/widgets.dart';

import '../jellyfin/jellyfin_credentials.dart';
import '../jellyfin/jellyfin_exceptions.dart';
import '../jellyfin/jellyfin_service.dart';
import '../jellyfin/jellyfin_session.dart';
import '../jellyfin/jellyfin_session_store.dart';

/// Manages authentication state and session lifecycle.
///
/// Responsibilities:
/// - User login/logout
/// - Session persistence and restoration
/// - Authentication state (loading, errors)
/// - Demo mode session setup
///
/// This provider is intentionally focused on auth only. It does NOT:
/// - Fetch library data (LibraryDataProvider's job)
/// - Manage UI state (UIStateProvider's job)
/// - Handle connectivity (ConnectivityService's job)
class SessionProvider extends ChangeNotifier {
  SessionProvider({
    required JellyfinService jellyfinService,
    required JellyfinSessionStore sessionStore,
  })  : _jellyfinService = jellyfinService,
        _sessionStore = sessionStore;

  final JellyfinService _jellyfinService;
  final JellyfinSessionStore _sessionStore;

  JellyfinSession? _session;
  bool _isAuthenticating = false;
  Object? _lastError;
  bool _initialized = false;

  // Locked-keychain handling (cold start from CarPlay / background).
  bool _storageUnavailable = false;
  Timer? _storageRetryTimer;
  AppLifecycleListener? _lifecycleListener;
  int _foregroundStorageFailures = 0;
  bool _retryInFlight = false;
  static const Duration _storageRetryInterval = Duration(seconds: 10);
  static const int _maxForegroundStorageFailures = 3;

  // Getters
  JellyfinSession? get session => _session;
  bool get isAuthenticated => _session != null;
  bool get isAuthenticating => _isAuthenticating;
  Object? get lastError => _lastError;
  bool get isInitialized => _initialized;
  bool get isDemoMode => _session?.isDemo ?? false;

  /// True while the stored session exists but can't be read yet (keychain
  /// locked). The provider stays uninitialized meanwhile so the UI doesn't
  /// drop to the login screen, and retries on resume / every 10 s.
  bool get isSessionStorageUnavailable => _storageUnavailable;

  /// Initialize the session provider by restoring any persisted session.
  ///
  /// This should be called once during app startup.
  /// Returns true if a session was restored, false otherwise.
  Future<bool> initialize() async {
    if (_initialized) {
      debugPrint('SessionProvider already initialized');
      return _session != null;
    }

    debugPrint('SessionProvider: Initializing...');
    return _restoreStoredSession();
  }

  Future<bool> _restoreStoredSession() async {
    try {
      final storedSession = await _sessionStore.load();
      _clearStorageRetry();
      if (storedSession != null) {
        _session = storedSession;

        // Only restore non-demo sessions to JellyfinService
        // Demo sessions are handled separately by demo mode logic
        if (!storedSession.isDemo) {
          _jellyfinService.restoreSession(storedSession);
        }

        debugPrint('SessionProvider: Restored session for ${storedSession.username}');
        _initialized = true;
        notifyListeners();
        return true;
      }

      debugPrint('SessionProvider: No stored session found');
      final wasInitialized = _initialized;
      _initialized = true;
      if (!wasInitialized) notifyListeners();
      return false;
    } on SessionStorageUnavailableException catch (error) {
      // Keychain locked: do NOT report "logged out". Stay uninitialized and
      // retry when the app resumes or periodically.
      debugPrint('SessionProvider: Session storage unavailable, will retry: $error');
      final inForeground = _isInForeground();
      if (inForeground) _foregroundStorageFailures++;
      if (inForeground &&
          _foregroundStorageFailures >= _maxForegroundStorageFailures) {
        // The device is unlocked and it still fails: stop blocking the UI.
        // Nothing has been deleted, so a later launch can still recover.
        debugPrint('SessionProvider: Storage still unavailable in foreground; giving up');
        _clearStorageRetry();
        _lastError = error;
        _initialized = true;
        notifyListeners();
        return false;
      }
      _scheduleStorageRetry();
      return false;
    } catch (error) {
      debugPrint('SessionProvider: Failed to restore session: $error');
      _lastError = error;
      _initialized = true;
      notifyListeners();
      return false;
    }
  }

  bool _isInForeground() {
    try {
      return WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    } catch (_) {
      return false;
    }
  }

  void _scheduleStorageRetry() {
    _storageUnavailable = true;
    _storageRetryTimer ??= Timer.periodic(_storageRetryInterval, (_) {
      unawaited(_retryStoredSession());
    });
    if (_lifecycleListener == null) {
      try {
        _lifecycleListener = AppLifecycleListener(
          onResume: () => unawaited(_retryStoredSession()),
        );
      } catch (e) {
        debugPrint('SessionProvider: lifecycle listener unavailable: $e');
      }
    }
  }

  Future<void> _retryStoredSession() async {
    if (!_storageUnavailable || _retryInFlight) return;
    _retryInFlight = true;
    try {
      await _restoreStoredSession();
    } finally {
      _retryInFlight = false;
    }
  }

  void _clearStorageRetry() {
    _storageUnavailable = false;
    _foregroundStorageFailures = 0;
    _storageRetryTimer?.cancel();
    _storageRetryTimer = null;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
  }

  /// Authenticate with a Jellyfin server.
  ///
  /// Throws JellyfinAuthException on authentication failure.
  Future<void> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    _lastError = null;
    _isAuthenticating = true;
    notifyListeners();

    try {
      final deviceId = await _sessionStore.getDeviceId();
      final session = await _jellyfinService.connect(
        serverUrl: serverUrl,
        username: username,
        password: password,
        deviceId: deviceId,
      );

      _session = session;
      _clearStorageRetry();
      await _sessionStore.save(session);

      debugPrint('SessionProvider: Login successful for $username');
    } catch (error) {
      debugPrint('SessionProvider: Login failed: $error');
      _lastError = error;
      rethrow;
    } finally {
      _isAuthenticating = false;
      notifyListeners();
    }
  }

  /// Log out and clear the current session.
  ///
  /// This clears both in-memory and persisted session data.
  /// Does NOT clear library data - that's LibraryDataProvider's responsibility.
  Future<void> logout() async {
    debugPrint('SessionProvider: Logging out...');

    _jellyfinService.clearSession();
    _session = null;
    try {
      await _sessionStore.clear();
    } finally {
      // Always notify so the UI leaves the logged-in state even if the
      // persisted session couldn't be cleared.
      notifyListeners();
    }
  }

  /// Start a demo session without connecting to a real server.
  ///
  /// This creates a fake session for demo/testing purposes.
  Future<void> startDemoSession({
    required String libraryId,
    required String libraryName,
  }) async {
    _lastError = null;
    _isAuthenticating = true;
    notifyListeners();

    try {
      _session = JellyfinSession(
        serverUrl: 'demo://nautune',
        username: 'tester',
        credentials: const JellyfinCredentials(
          accessToken: 'demo-token',
          userId: 'demo-user',
        ),
        deviceId: 'demo-device',
        selectedLibraryId: libraryId,
        selectedLibraryName: libraryName,
        isDemo: true,
      );

      // Don't persist demo sessions to avoid confusion
      // Users should explicitly start demo mode each time

      debugPrint('SessionProvider: Demo session started');
    } catch (error) {
      _lastError = error;
      rethrow;
    } finally {
      _isAuthenticating = false;
      notifyListeners();
    }
  }

  /// Update the selected library in the current session.
  ///
  /// This is used when the user switches libraries.
  Future<void> updateSelectedLibrary({
    required String libraryId,
    required String libraryName,
  }) async {
    final session = _session;
    if (session == null) {
      throw Exception('No active session');
    }

    final updated = session.copyWith(
      selectedLibraryId: libraryId,
      selectedLibraryName: libraryName,
    );

    _session = updated;

    // Don't persist demo sessions
    if (!session.isDemo) {
      await _sessionStore.save(updated);
    }

    notifyListeners();
  }

  /// Clear the selected library from the current session.
  Future<void> clearSelectedLibrary() async {
    final session = _session;
    if (session == null) return;

    final updated = session.copyWith(
      selectedLibraryId: null,
      selectedLibraryName: null,
    );

    _session = updated;

    if (!session.isDemo) {
      await _sessionStore.save(updated);
    }

    notifyListeners();
  }

  /// Clear any authentication errors.
  void clearError() {
    if (_lastError != null) {
      _lastError = null;
      notifyListeners();
    }
  }

  /// Force logout when the session becomes unauthorized.
  ///
  /// This should be called by other parts of the app when they detect
  /// an unauthorized/expired session.
  Future<void> handleUnauthorizedSession() async {
    debugPrint('SessionProvider: Handling unauthorized session');
    _lastError = JellyfinAuthException('Session expired. Please log in again.');
    notifyListeners();
    await logout();
  }

  @override
  void dispose() {
    _clearStorageRetry();
    _session = null;
    super.dispose();
  }
}
